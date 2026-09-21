//
//  ContentSyncManager+Plex.swift
//  Lume
//
//  The Plex sync pipeline: resolve a token, read the movie and TV-show
//  sections one at a time, and upsert the items into the catalog rows the
//  rest of the app already renders. Same shape as the Jellyfin/Emby pipeline
//  — server metadata is trusted as-is — but Plex's API is its own: every
//  response is a `MediaContainer`, and a section's episodes come back in one
//  flat query rather than per show.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// One section's import scope: everything the per-page upserts need beyond
    /// the items themselves. Bundled so the pipeline's helpers stay under the
    /// parameter-count lint.
    ///
    /// Not `private`: shared with `ContentSyncManager+PlexShows.swift`.
    struct PlexSectionScope {
        var server: URL
        var token: String?
        var playlistId: UUID
        var section: PlexSection
        var categoryId: String

        /// The id prefix every row of this section carries. The `plex` infix
        /// scopes the prune sweeps to rows this pipeline owns.
        var idPrefix: String {
            "\(playlistId.uuidString)-plex-"
        }
    }

    func performPlexSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?) async throws {
        guard let base = URL(string: playlist.serverURL), base.scheme != nil, base.host != nil else {
            throw PlexError.invalidURL
        }
        let server = PlexClient.normalizedServerURL(base)

        await progress?.start(.authenticating)
        let session: PlexSession
        do {
            session = try await resolvePlexSession(playlist: playlist, server: server)
        } catch {
            let described = (error as? PlexError)?.logDescription ?? "login failed"
            Logger.database.error("Plex login aborted (\(described, privacy: .public)); catalog untouched")
            throw error
        }
        let token = session.token
        persistPlexToken(token, playlistId: playlistId)
        await progress?.complete(.authenticating)

        let sections = session.sections
        let movieSections = sections.filter { $0.type == "movie" }
        let showSections = sections.filter { $0.type == "show" }
        if movieSections.isEmpty, showSections.isEmpty {
            Logger.database.info("Plex sync: no movie or TV-show sections; catalog untouched")
        }

        try syncPlexCategories(sections: movieSections, type: .vod, playlistId: playlistId)
        try syncPlexCategories(sections: showSections, type: .series, playlistId: playlistId)

        await progress?.start(.movies)
        var seenMovies = Set<String>()
        for section in movieSections {
            let scope = scope(server: server, token: token, playlistId: playlistId, section: section, type: .vod)
            try await syncPlexMovies(scope: scope, seenIds: &seenMovies, progress: progress)
        }
        prunePlexMovies(playlistId: playlistId, seenIds: seenMovies, fetched: !movieSections.isEmpty)
        await progress?.complete(.movies)

        await progress?.start(.series)
        var seenSeries = Set<String>()
        var seenEpisodes = Set<String>()
        for section in showSections {
            let scope = scope(server: server, token: token, playlistId: playlistId, section: section, type: .series)
            try await syncPlexShows(scope: scope, seenSeries: &seenSeries, seenEpisodes: &seenEpisodes, progress: progress)
        }
        prunePlexSeries(playlistId: playlistId, seenSeries: seenSeries, seenEpisodes: seenEpisodes, fetched: !showSections.isEmpty)
        await progress?.complete(.series)

        markPlaylistUpdated(playlistId)
    }

    private func scope(server: URL, token: String?, playlistId: UUID, section: PlexSection, type: CategoryType) -> PlexSectionScope {
        PlexSectionScope(
            server: server, token: token, playlistId: playlistId, section: section,
            categoryId: "\(playlistId.uuidString)-\(type.rawValue)-\(section.key)"
        )
    }

    // MARK: - Token

    /// An authenticated connection: the token to use (possibly none) and the
    /// section list that proved it works.
    private struct PlexSession {
        var token: String?
        var sections: [PlexSection]
    }

    /// Establishes the session this sync runs on, by asking for the section
    /// list — the cheapest call the token actually gates.
    ///
    /// A stored token is tried first and, if the server has since revoked it,
    /// the credential sources are walked again rather than failing the sync
    /// until the user edits the playlist. That walk is the same order
    /// `PlexAddCheck` uses, including its reason for preferring no token over
    /// a pasted one.
    private func resolvePlexSession(playlist: Playlist, server: URL) async throws -> PlexSession {
        let username = playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = playlist.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSignIn = !username.isEmpty && !secret.isEmpty

        if let stored = playlist.plexAccessToken, !stored.isEmpty {
            do {
                return try await session(server: server, token: stored)
            } catch PlexError.unauthorized {
                Logger.database.info("Plex token rejected; resolving a fresh credential")
            }
        }
        if canSignIn {
            return try await session(server: server, token: plexClient.signIn(username: username, password: playlist.password))
        }
        do {
            return try await session(server: server, token: nil)
        } catch PlexError.unauthorized {
            guard !secret.isEmpty else { throw PlexError.unauthorized }
            return try await session(server: server, token: secret)
        }
    }

    private func session(server: URL, token: String?) async throws -> PlexSession {
        try await PlexSession(token: token, sections: plexClient.sections(server: server, token: token))
    }

    /// Stores the resolved token on the playlist so playback and artwork can
    /// authenticate without signing in again. A revoked token is replaced on
    /// the next sync, which signs in whenever the stored one is gone.
    private func persistPlexToken(_ token: String?, playlistId: UUID) {
        guard let token, !token.isEmpty else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        if playlist.plexAccessToken != token {
            playlist.plexAccessToken = token
            try? context.save()
        }
    }

    // MARK: - Paging

    /// Pages a section query to exhaustion, handing each page to `body`.
    /// Returns the number of items seen. Shared by the movie, show and
    /// episode walks so the three differ only in what they do per page.
    /// Not `private`: shared with `ContentSyncManager+PlexShows.swift`.
    func pageThroughPlexItems(
        type: Int,
        scope: PlexSectionScope,
        progress: SyncProgress?,
        unit: String,
        body: ([PlexMetadata]) -> Void
    ) async throws -> Int {
        var start = 0
        var total = Int.max
        var fetched = 0
        while fetched < total {
            try Task.checkCancellation()
            let page = try await plexClient.items(
                server: scope.server, token: scope.token, sectionKey: scope.section.key,
                type: type, start: start
            )
            total = page.totalSize
            if !page.items.isEmpty {
                body(page.items)
            }
            fetched += page.items.count
            start += page.items.count
            await progress?.update(
                detail: "\(fetched) of \(total) \(unit) in \(scope.section.title)",
                fraction: total == 0 ? 1 : Double(fetched) / Double(total)
            )
            if page.items.isEmpty {
                break
            }
        }
        return fetched
    }

    // MARK: - Categories

    /// One category per Plex section, updated in place so a rename keeps
    /// `isHidden` / `customOrder`. Mirrors `syncCategories`' empty-gate: an
    /// empty section list is the transient-failure signature, never a
    /// deletion.
    private func syncPlexCategories(sections: [PlexSection], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let lookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, section) in sections.enumerated() {
            if let existing = lookup[section.key] {
                if existing.name != section.title {
                    existing.name = section.title
                }
                if existing.sortOrder != index {
                    existing.sortOrder = index
                }
                existing.lastRefreshed = Date()
            } else {
                let category = Category(apiId: section.key, name: section.title, parentId: 0, type: type, playlist: playlist)
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }
        if context.hasChanges {
            try context.save()
        }

        if !sections.isEmpty {
            pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: Set(sections.map(\.key)))
        }
    }

    // MARK: - Movies

    private func syncPlexMovies(scope: PlexSectionScope, seenIds: inout Set<String>, progress: SyncProgress?) async throws {
        var seen = seenIds
        let fetched = try await pageThroughPlexItems(
            type: PlexClient.movieType, scope: scope, progress: progress, unit: "movie(s)"
        ) { items in
            seen.formUnion(upsertPlexMovies(items, scope: scope))
        }
        seenIds = seen
        Logger.database.info("Plex movies synced for section \(scope.section.title, privacy: .public): \(fetched, privacy: .public) item(s)")
    }

    /// Upserts one page of movies, returning the ids it saw for the prune
    /// sweep. A set (not an inout) so the paging loop can feed pages through a
    /// closure, which cannot capture an inout parameter.
    private func upsertPlexMovies(_ items: [PlexMetadata], scope: PlexSectionScope) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.map { scope.idPrefix + $0.ratingKey }
        var lookup: [String: Movie] = [:]
        let existing = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for movie in existing {
            lookup[movie.id] = movie
        }

        for item in items {
            let id = scope.idPrefix + item.ratingKey
            let movie: Movie
            if let found = lookup[id] {
                movie = found
            } else {
                movie = Movie(id: id, streamId: Self.plexStreamId(item.ratingKey), name: item.title ?? "")
                context.insert(movie)
            }
            applyPlexMovieFields(item, to: movie, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return Set(ids)
    }

    /// Copies the server-owned fields onto the row, leaving user state
    /// (favorites, progress, downloads) intact. Every write is inequality
    /// guarded: SwiftData dirties a row on assignment, not on change. Split in
    /// two halves (identity + metadata) for the complexity lint.
    private func applyPlexMovieFields(_ item: PlexMetadata, to movie: Movie, scope: PlexSectionScope) {
        applyPlexMovieIdentity(item, to: movie, scope: scope)
        applyPlexMovieMetadata(item, to: movie)
    }

    private func applyPlexMovieIdentity(_ item: PlexMetadata, to movie: Movie, scope: PlexSectionScope) {
        let name = item.title ?? ""
        if movie.name != name {
            movie.name = name
        }
        if movie.categoryId != scope.categoryId {
            movie.categoryId = scope.categoryId
        }
        if let part = item.partKey,
           let url = PlexClient.streamURL(server: scope.server, partKey: part)?.absoluteString,
           movie.directURL != url
        {
            movie.directURL = url
        }
        if let thumb = item.thumb,
           let url = PlexClient.imageURL(server: scope.server, path: thumb, token: scope.token)?.absoluteString,
           movie.streamIcon != url
        {
            movie.streamIcon = url
        }
        // Plex rates on a 0–10 scale like Jellyfin's `CommunityRating`; the
        // audience score stands in when a critic score is missing.
        let rating = item.rating ?? item.audienceRating ?? 0
        if movie.rating != rating {
            movie.rating = rating
        }
        if movie.rating5Based != rating / 2 {
            movie.rating5Based = rating / 2
        }
    }

    private func applyPlexMovieMetadata(_ item: PlexMetadata, to movie: Movie) {
        if movie.plot != item.summary {
            movie.plot = item.summary
        }
        if movie.genre != item.genreList {
            movie.genre = item.genreList
        }
        if movie.releaseDate != item.originallyAvailableAt {
            movie.releaseDate = item.originallyAvailableAt
        }
        if movie.durationSecs != item.durationSecs {
            movie.durationSecs = item.durationSecs
        }
        if let container = item.container?.lowercased(), movie.containerExtension != container {
            movie.containerExtension = container
        }
        if let tmdb = item.providerId("tmdb"), movie.tmdb != tmdb {
            movie.tmdb = tmdb
        }
        if let imdb = item.providerId("imdb"), movie.imdbId != imdb {
            movie.imdbId = imdb
        }
        let added = item.addedAt.map { Self.plexDateString(from: $0) }
        if movie.added != added {
            movie.added = added
        }
    }

    /// Removes movies the server no longer lists. Gated on `fetched`: an empty
    /// section list is the transient-failure signature, and sweeping then
    /// would drop the whole catalog.
    private func prunePlexMovies(playlistId: UUID, seenIds: Set<String>, fetched: Bool) {
        guard fetched else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = playlistId.uuidString
        let rows = (try? context.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        ))) ?? []
        // Only rows this pipeline owns carry the `-plex-` infix; anything else
        // under the prefix belongs to another source and is left alone.
        for movie in rows where movie.id.contains("-plex-") && !seenIds.contains(movie.id) {
            context.delete(movie)
        }
        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Helpers

    /// Plex `ratingKey`s are numeric strings, so the `streamId`/`seriesId`
    /// columns can carry the real id. A non-numeric key (never seen in
    /// practice, but the API types it as a string) falls back to the same
    /// launch-stable hash the Jellyfin/Emby pipeline uses.
    nonisolated static func plexStreamId(_ ratingKey: String) -> Int {
        Int(ratingKey) ?? mediaServerHash(ratingKey)
    }

    /// `addedAt` is Unix seconds; the catalog's `added` column is the
    /// `yyyy-MM-dd` string every other source writes.
    nonisolated static func plexDateString(from unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
