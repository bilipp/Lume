//
//  ContentSyncManager+MediaServer.swift
//  Lume
//
//  The Jellyfin/Emby sync pipeline: authenticate, read the movie and TV-show
//  libraries view by view, and upsert the items into the catalog rows the
//  rest of the app already renders. Server metadata is trusted as-is —
//  unlike a file share there is nothing to classify by filename.
//
//  One pipeline serves both products because they are wire-compatible; the
//  only thing that varies is the `MediaServerFlavor` its rows are tagged with.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// What every request of one sync shares: where the server is, who we
    /// are on it, and which product it is.
    struct JellyfinConnection {
        var server: URL
        var session: JellyfinSession
        var flavor: MediaServerFlavor
    }

    /// One library's import scope: everything the per-page upserts need beyond
    /// the items themselves. Bundled so the pipeline's helpers stay under the
    /// parameter-count lint.
    ///
    /// Not `private`: shared with `ContentSyncManager+MediaServerShows.swift`.
    struct JellyfinViewScope {
        var connection: JellyfinConnection
        var playlistId: UUID
        var view: JellyfinLibrary
        var categoryId: String

        var server: URL {
            connection.server
        }

        var session: JellyfinSession {
            connection.session
        }

        var flavor: MediaServerFlavor {
            connection.flavor
        }

        /// The id prefix every row of this library carries. The flavour infix
        /// is what scopes the prune sweeps (see `MediaServerFlavor.idInfix`).
        var idPrefix: String {
            "\(playlistId.uuidString)-\(flavor.idInfix)-"
        }
    }

    func performMediaServerSync(playlist: Playlist, playlistId: UUID, flavor: MediaServerFlavor, progress: SyncProgress?) async throws {
        guard let base = URL(string: playlist.serverURL), base.scheme != nil, base.host != nil else {
            throw JellyfinError.invalidURL
        }
        let server = JellyfinClient.normalizedServerURL(base)

        await progress?.start(.authenticating)
        let session: JellyfinSession
        do {
            session = try await jellyfinClient.authenticate(server: server, username: playlist.username, password: playlist.password)
        } catch {
            let described = (error as? JellyfinError)?.logDescription ?? "login failed"
            let product = flavor.displayName
            Logger.database.error("\(product, privacy: .public) login aborted (\(described, privacy: .public)); catalog untouched")
            throw error
        }
        persistJellyfinSession(session, playlistId: playlistId)
        await progress?.complete(.authenticating)

        let connection = JellyfinConnection(server: server, session: session, flavor: flavor)
        let views = try await jellyfinClient.views(server: server, session: session)
        // A mixed-content library reports no `CollectionType` at all, and both
        // products let you make one. Walking it for movies *and* shows is what
        // keeps such a server from importing nothing at all; a library that is
        // neither (music, photos, books) still names its type and is skipped.
        // A non-media folder that happens to report no type costs one empty
        // query per kind, because the item query filters by type anyway.
        let movieViews = views.filter { $0.collectionType == "movies" || $0.collectionType == nil }
        let showViews = views.filter { $0.collectionType == "tvshows" || $0.collectionType == nil }
        if movieViews.isEmpty, showViews.isEmpty {
            Logger.database.info("\(flavor.displayName, privacy: .public) sync: no movie or TV-show libraries; catalog untouched")
        }

        try await syncJellyfinCategories(views: movieViews, type: .vod, playlistId: playlistId)
        try await syncJellyfinCategories(views: showViews, type: .series, playlistId: playlistId)

        await progress?.start(.movies)
        var seenMovies = Set<String>()
        for view in movieViews {
            let viewScope = scope(connection, playlistId: playlistId, view: view, type: .vod)
            try await syncJellyfinMovies(scope: viewScope, seenIds: &seenMovies, progress: progress)
        }
        pruneJellyfinMovies(playlistId: playlistId, flavor: flavor, seenIds: seenMovies, fetched: !movieViews.isEmpty)
        await progress?.complete(.movies)

        await progress?.start(.series)
        var seenSeries = Set<String>()
        var seenEpisodes = Set<String>()
        for view in showViews {
            let viewScope = scope(connection, playlistId: playlistId, view: view, type: .series)
            try await syncJellyfinShows(scope: viewScope, seenSeries: &seenSeries, seenEpisodes: &seenEpisodes, progress: progress)
        }
        pruneJellyfinSeries(playlistId: playlistId, flavor: flavor, seenSeries: seenSeries, seenEpisodes: seenEpisodes, fetched: !showViews.isEmpty)
        await progress?.complete(.series)

        markPlaylistUpdated(playlistId)
    }

    private func scope(_ connection: JellyfinConnection, playlistId: UUID, view: JellyfinLibrary, type: CategoryType) -> JellyfinViewScope {
        JellyfinViewScope(
            connection: connection, playlistId: playlistId, view: view,
            categoryId: "\(playlistId.uuidString)-\(type.rawValue)-\(view.id)"
        )
    }

    // MARK: - Paging

    /// Pages a recursive item query to exhaustion, handing each page to `body`.
    /// Returns the number of items seen. Shared by the movie, series and
    /// episode walks so the three differ only in what they do per page.
    /// Not `private`: shared with `ContentSyncManager+MediaServerShows.swift`.
    func pageThroughJellyfinItems(
        types: [String],
        scope: JellyfinViewScope,
        progress: SyncProgress?,
        unit: String,
        body: ([JellyfinItem]) -> Void
    ) async throws -> Int {
        var startIndex = 0
        var total = Int.max
        var fetched = 0
        while fetched < total {
            try Task.checkCancellation()
            let page = try await jellyfinClient.items(
                server: scope.server, session: scope.session, parentId: scope.view.id, types: types,
                startIndex: startIndex
            )
            total = page.totalRecordCount
            if !page.items.isEmpty {
                body(page.items)
            }
            fetched += page.items.count
            startIndex += page.items.count
            await progress?.update(detail: "\(fetched) of \(total) \(unit) in \(scope.view.name)", fraction: total == 0 ? 1 : Double(fetched) / Double(total))
            if page.items.isEmpty {
                break
            }
        }
        return fetched
    }

    // MARK: - Session

    /// Stores the fresh session on the playlist so playback and artwork can
    /// authenticate without logging in again. A rotated or revoked token is
    /// simply replaced on the next sync, which always logs in first.
    private func persistJellyfinSession(_ session: JellyfinSession, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.jellyfinAccessToken = session.accessToken
        playlist.jellyfinUserId = session.userId
        try? context.save()
    }

    // MARK: - Categories

    /// One category per Jellyfin library, updated in place so a rename keeps
    /// `isHidden` / `customOrder`. Mirrors `syncCategories`' empty-gate: an
    /// empty view list is the transient-failure signature, never a deletion.
    private func syncJellyfinCategories(views: [JellyfinLibrary], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let lookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, view) in views.enumerated() {
            if let existing = lookup[view.id] {
                if existing.name != view.name {
                    existing.name = view.name
                }
                if existing.sortOrder != index {
                    existing.sortOrder = index
                }
                existing.lastRefreshed = Date()
            } else {
                let category = Category(apiId: view.id, name: view.name, parentId: 0, type: type, playlist: playlist)
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }
        if context.hasChanges {
            try context.save()
        }

        if !views.isEmpty {
            pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: Set(views.map(\.id)))
        }
    }

    // MARK: - Movies

    private func syncJellyfinMovies(scope: JellyfinViewScope, seenIds: inout Set<String>, progress: SyncProgress?) async throws {
        var seen = seenIds
        let fetched = try await pageThroughJellyfinItems(types: ["Movie"], scope: scope, progress: progress, unit: "movie(s)") { items in
            seen.formUnion(upsertJellyfinMovies(items, scope: scope))
        }
        seenIds = seen
        Logger.database.info("\(scope.flavor.displayName, privacy: .public) movies synced for library \(scope.view.name, privacy: .public): \(fetched, privacy: .public) item(s)")
    }

    /// Upserts one page of movies, returning the ids it saw for the prune
    /// sweep. A set (not an inout) so the paging loop can feed pages through a
    /// closure, which cannot capture an inout parameter.
    private func upsertJellyfinMovies(_ items: [JellyfinItem], scope: JellyfinViewScope) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.map { scope.idPrefix + $0.id }
        var lookup: [String: Movie] = [:]
        let existing = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for movie in existing {
            lookup[movie.id] = movie
        }

        for item in items {
            let id = scope.idPrefix + item.id
            let movie: Movie
            if let found = lookup[id] {
                movie = found
            } else {
                movie = Movie(id: id, streamId: Self.mediaServerHash(item.id), name: item.name ?? "")
                context.insert(movie)
            }
            applyJellyfinMovieFields(item, to: movie, scope: scope)
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
    private func applyJellyfinMovieFields(_ item: JellyfinItem, to movie: Movie, scope: JellyfinViewScope) {
        applyJellyfinMovieIdentity(item, to: movie, scope: scope)
        applyJellyfinMovieMetadata(item, to: movie)
    }

    private func applyJellyfinMovieIdentity(_ item: JellyfinItem, to movie: Movie, scope: JellyfinViewScope) {
        let name = item.name ?? ""
        if movie.name != name {
            movie.name = name
        }
        if movie.categoryId != scope.categoryId {
            movie.categoryId = scope.categoryId
        }
        if let url = JellyfinClient.streamURL(server: scope.server, itemId: item.id)?.absoluteString,
           movie.directURL != url
        {
            movie.directURL = url
        }
        if let tag = item.primaryImageTag,
           let url = JellyfinClient.imageURL(server: scope.server, itemId: item.id, tag: tag, token: scope.session.accessToken)?.absoluteString,
           movie.streamIcon != url
        {
            movie.streamIcon = url
        }
        let rating = item.communityRating ?? 0
        if movie.rating != rating {
            movie.rating = rating
        }
        if movie.rating5Based != rating / 2 {
            movie.rating5Based = rating / 2
        }
    }

    private func applyJellyfinMovieMetadata(_ item: JellyfinItem, to movie: Movie) {
        if movie.plot != item.overview {
            movie.plot = item.overview
        }
        let genre = item.genres?.joined(separator: ", ")
        if movie.genre != genre {
            movie.genre = genre
        }
        let release = item.premiereDate.map { String($0.prefix(10)) }
        if movie.releaseDate != release {
            movie.releaseDate = release
        }
        if movie.durationSecs != item.durationSecs {
            movie.durationSecs = item.durationSecs
        }
        if let container = item.container?.split(separator: ",").first.map({ String($0).lowercased() }),
           movie.containerExtension != container
        {
            movie.containerExtension = container
        }
        if let tmdb = item.providerIds?["Tmdb"], movie.tmdb != tmdb {
            movie.tmdb = tmdb
        }
        if let imdb = item.providerIds?["Imdb"], movie.imdbId != imdb {
            movie.imdbId = imdb
        }
        let added = item.dateCreated.map { String($0.prefix(10)) }
        if movie.added != added {
            movie.added = added
        }
    }

    /// Removes movies the server no longer lists. Gated on `fetched`: an empty
    /// library list is the transient-failure signature, and sweeping then
    /// would drop the whole catalog.
    private func pruneJellyfinMovies(playlistId: UUID, flavor: MediaServerFlavor, seenIds: Set<String>, fetched: Bool) {
        guard fetched else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = playlistId.uuidString
        let rows = (try? context.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        ))) ?? []
        // Only rows this pipeline owns carry the flavour infix; anything else
        // under the prefix belongs to another source and is left alone.
        let infix = "-\(flavor.idInfix)-"
        for movie in rows where movie.id.contains(infix) && !seenIds.contains(movie.id) {
            context.delete(movie)
        }
        if context.hasChanges {
            try? context.save()
        }
    }
}
