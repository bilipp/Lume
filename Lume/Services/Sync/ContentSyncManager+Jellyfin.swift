//
//  ContentSyncManager+Jellyfin.swift
//  Lume
//
//  The Jellyfin sync pipeline: authenticate, read the movie and TV-show
//  libraries view by view, and upsert the items into the catalog rows the
//  rest of the app already renders. Server metadata is trusted as-is —
//  unlike a file share there is nothing to classify by filename.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// One library's import scope: everything the per-page upserts need beyond
    /// the items themselves. Bundled so the pipeline's helpers stay under the
    /// parameter-count lint.
    private struct JellyfinViewScope {
        var server: URL
        var session: JellyfinSession
        var playlistId: UUID
        var view: JellyfinLibrary
        var categoryId: String
    }

    func performJellyfinSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?) async throws {
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
            Logger.database.error("Jellyfin login aborted (\(described, privacy: .public)); catalog untouched")
            throw error
        }
        persistJellyfinSession(session, playlistId: playlistId)
        await progress?.complete(.authenticating)

        let views = try await jellyfinClient.views(server: server, session: session)
        let movieViews = views.filter { $0.collectionType == "movies" }
        let showViews = views.filter { $0.collectionType == "tvshows" }
        if movieViews.isEmpty, showViews.isEmpty {
            Logger.database.info("Jellyfin sync: no movie or TV-show libraries; catalog untouched")
        }

        try await syncJellyfinCategories(views: movieViews, type: .vod, playlistId: playlistId)
        try await syncJellyfinCategories(views: showViews, type: .series, playlistId: playlistId)

        await progress?.start(.movies)
        var seenMovies = Set<String>()
        for view in movieViews {
            let viewScope = scope(server: server, session: session, playlistId: playlistId, view: view, type: .vod)
            try await syncJellyfinMovies(scope: viewScope, seenIds: &seenMovies, progress: progress)
        }
        pruneJellyfinMovies(playlistId: playlistId, seenIds: seenMovies, fetched: !movieViews.isEmpty)
        await progress?.complete(.movies)

        await progress?.start(.series)
        var seenSeries = Set<String>()
        var seenEpisodes = Set<String>()
        for view in showViews {
            let viewScope = scope(server: server, session: session, playlistId: playlistId, view: view, type: .series)
            try await syncJellyfinShows(scope: viewScope, seenSeries: &seenSeries, seenEpisodes: &seenEpisodes, progress: progress)
        }
        pruneJellyfinSeries(playlistId: playlistId, seenSeries: seenSeries, seenEpisodes: seenEpisodes, fetched: !showViews.isEmpty)
        await progress?.complete(.series)

        markPlaylistUpdated(playlistId)
    }

    private func scope(server: URL, session: JellyfinSession, playlistId: UUID, view: JellyfinLibrary, type: CategoryType) -> JellyfinViewScope {
        JellyfinViewScope(
            server: server, session: session, playlistId: playlistId, view: view,
            categoryId: "\(playlistId.uuidString)-\(type.rawValue)-\(view.id)"
        )
    }

    // MARK: - Paging

    /// Pages a recursive item query to exhaustion, handing each page to `body`.
    /// Returns the number of items seen. Shared by the movie, series and
    /// episode walks so the three differ only in what they do per page.
    private func pageThroughJellyfinItems(
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
        Logger.database.info("Jellyfin movies synced for library \(scope.view.name, privacy: .public): \(fetched, privacy: .public) item(s)")
    }

    /// Upserts one page of movies, returning the ids it saw for the prune
    /// sweep. A set (not an inout) so the paging loop can feed pages through a
    /// closure, which cannot capture an inout parameter.
    private func upsertJellyfinMovies(_ items: [JellyfinItem], scope: JellyfinViewScope) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.map { "\(scope.playlistId.uuidString)-jellyfin-\($0.id)" }
        var lookup: [String: Movie] = [:]
        let existing = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for movie in existing {
            lookup[movie.id] = movie
        }

        for item in items {
            let id = "\(scope.playlistId.uuidString)-jellyfin-\(item.id)"
            let movie: Movie
            if let found = lookup[id] {
                movie = found
            } else {
                movie = Movie(id: id, streamId: Self.jellyfinHash(item.id), name: item.name ?? "")
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
    private func pruneJellyfinMovies(playlistId: UUID, seenIds: Set<String>, fetched: Bool) {
        guard fetched else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = playlistId.uuidString
        let rows = (try? context.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        ))) ?? []
        // Only rows this pipeline owns carry the `-jellyfin-` infix; anything
        // else under the prefix belongs to another source and is left alone.
        for movie in rows where movie.id.contains("-jellyfin-") && !seenIds.contains(movie.id) {
            context.delete(movie)
        }
        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Series & episodes

    private func syncJellyfinShows(scope: JellyfinViewScope, seenSeries: inout Set<String>, seenEpisodes: inout Set<String>, progress: SyncProgress?) async throws {
        // Series shells first, so episodes below can link against them.
        var seriesByJellyfinId: [String: JellyfinItem] = [:]
        var seen = seenSeries
        _ = try await pageThroughJellyfinItems(types: ["Series"], scope: scope, progress: nil, unit: "series") { items in
            seen.formUnion(upsertJellyfinSeries(items, scope: scope))
            for item in items {
                seriesByJellyfinId[item.id] = item
            }
        }

        // Then every episode, grouped by its series. An episode whose series
        // shell is missing (a stale `SeriesId`, or a library the server filed
        // oddly) still imports under a shell built from its `SeriesName` so no
        // playable file is ever dropped.
        var seenEp = seenEpisodes
        let shells = seriesByJellyfinId
        let episodeCount = try await pageThroughJellyfinItems(types: ["Episode"], scope: scope, progress: progress, unit: "episode(s)") { items in
            let (series, episodes) = upsertJellyfinEpisodes(items, seriesShells: shells, scope: scope)
            seen.formUnion(series)
            seenEp.formUnion(episodes)
        }
        seenSeries = seen
        seenEpisodes = seenEp
        Logger.database.info("Jellyfin shows synced for library \(scope.view.name, privacy: .public): \(episodeCount, privacy: .public) episode(s)")
    }

    private func upsertJellyfinSeries(_ items: [JellyfinItem], scope: JellyfinViewScope) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.map { "\(scope.playlistId.uuidString)-jellyfin-\($0.id)" }
        let lookup = existingSeries(ids: ids, context: context)

        for item in items {
            let id = "\(scope.playlistId.uuidString)-jellyfin-\(item.id)"
            let series: Series
            if let found = lookup[id] {
                series = found
            } else {
                series = Series(id: id, seriesId: Self.jellyfinHash(item.id), name: item.name ?? "")
                context.insert(series)
            }
            applyJellyfinSeriesFields(item, to: series, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return Set(ids)
    }

    private func applyJellyfinSeriesFields(_ item: JellyfinItem, to series: Series, scope: JellyfinViewScope) {
        let name = item.name ?? ""
        if series.name != name {
            series.name = name
        }
        if series.categoryId != scope.categoryId {
            series.categoryId = scope.categoryId
        }
        if let tag = item.primaryImageTag,
           let url = JellyfinClient.imageURL(server: scope.server, itemId: item.id, tag: tag, token: scope.session.accessToken)?.absoluteString,
           series.cover != url
        {
            series.cover = url
        }
        if series.plot != item.overview {
            series.plot = item.overview
        }
        let genre = item.genres?.joined(separator: ", ")
        if series.genre != genre {
            series.genre = genre
        }
        let release = item.premiereDate.map { String($0.prefix(10)) }
        if series.releaseDate != release {
            series.releaseDate = release
        }
        if let rating = item.communityRating.map({ String($0) }),
           series.rating != rating
        {
            series.rating = rating
        }
        if let tmdb = item.providerIds?["Tmdb"], series.tmdb != tmdb {
            series.tmdb = tmdb
        }
        if let imdb = item.providerIds?["Imdb"], series.imdbId != imdb {
            series.imdbId = imdb
        }
    }

    private func upsertJellyfinEpisodes(_ items: [JellyfinItem], seriesShells: [String: JellyfinItem], scope: JellyfinViewScope) -> (series: Set<String>, episodes: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // The series rows these episodes link against — shells already stored
        // plus fallback shells for episodes whose `SeriesId` has no shell.
        var seriesIds: Set<String> = []
        for item in items {
            let shellId = item.seriesId ?? item.id
            seriesIds.insert("\(scope.playlistId.uuidString)-jellyfin-\(shellId)")
        }
        var seriesLookup = existingSeries(ids: Array(seriesIds), context: context)

        let episodeIds = items.map { "\(scope.playlistId.uuidString)-jellyfin-episode-\($0.id)" }
        let episodeLookup = existingEpisodes(ids: episodeIds, context: context)

        var seenSeries = Set<String>()
        for item in items {
            let series = seriesRow(for: item, seriesShells: seriesShells, scope: scope, lookup: &seriesLookup, context: context)
            seenSeries.insert(series.id)
            let episode = episodeRow(for: item, series: series, lookup: episodeLookup, scope: scope, context: context)
            applyJellyfinEpisodeFields(item, to: episode, series: series, scope: scope)
        }
        if context.hasChanges {
            try? context.save()
        }
        return (seenSeries, Set(episodeIds))
    }

    /// The stored (or freshly built) series row an episode links against. A
    /// missing shell is built from the episode's `SeriesName` so no playable
    /// file is ever dropped for a stale `SeriesId`.
    private func seriesRow(
        for item: JellyfinItem,
        seriesShells: [String: JellyfinItem],
        scope: JellyfinViewScope,
        lookup: inout [String: Series],
        context: ModelContext
    ) -> Series {
        let shellJellyfinId = item.seriesId ?? item.id
        let seriesId = "\(scope.playlistId.uuidString)-jellyfin-\(shellJellyfinId)"
        if let found = lookup[seriesId] {
            return found
        }
        let shellName = item.seriesName ?? seriesShells[shellJellyfinId]?.name ?? item.name ?? ""
        let series = Series(id: seriesId, seriesId: Self.jellyfinHash(shellJellyfinId), name: shellName)
        if let shell = seriesShells[shellJellyfinId] {
            applyJellyfinSeriesFields(shell, to: series, scope: scope)
        } else if series.categoryId != scope.categoryId {
            series.categoryId = scope.categoryId
        }
        context.insert(series)
        lookup[seriesId] = series
        return series
    }

    private func episodeRow(
        for item: JellyfinItem,
        series: Series,
        lookup: [String: Episode],
        scope: JellyfinViewScope,
        context: ModelContext
    ) -> Episode {
        let id = "\(scope.playlistId.uuidString)-jellyfin-episode-\(item.id)"
        if let found = lookup[id] {
            return found
        }
        let episode = Episode(
            id: id, episodeId: item.id, title: item.name ?? "",
            containerExtension: item.container?.lowercased() ?? "mkv",
            seasonNum: item.parentIndexNumber ?? 1, episodeNum: item.indexNumber ?? 0
        )
        context.insert(episode)
        episode.series = series
        return episode
    }

    private func applyJellyfinEpisodeFields(_ item: JellyfinItem, to episode: Episode, series: Series, scope: JellyfinViewScope) {
        applyJellyfinEpisodeIdentity(item, to: episode, scope: scope)
        applyJellyfinEpisodeMetadata(item, to: episode, series: series, scope: scope)
    }

    private func applyJellyfinEpisodeIdentity(_ item: JellyfinItem, to episode: Episode, scope: JellyfinViewScope) {
        let title = item.name ?? ""
        if episode.title != title {
            episode.title = title
        }
        if let season = item.parentIndexNumber, episode.seasonNum != season {
            episode.seasonNum = season
        }
        if let number = item.indexNumber, episode.episodeNum != number {
            episode.episodeNum = number
        }
        if let url = JellyfinClient.streamURL(server: scope.server, itemId: item.id)?.absoluteString,
           episode.directSource != url
        {
            episode.directSource = url
        }
        if let container = item.container?.lowercased(), episode.containerExtension != container {
            episode.containerExtension = container
        }
    }

    private func applyJellyfinEpisodeMetadata(_ item: JellyfinItem, to episode: Episode, series: Series, scope: JellyfinViewScope) {
        let image: String? = {
            if let tag = item.primaryImageTag {
                return JellyfinClient.imageURL(server: scope.server, itemId: item.id, tag: tag, token: scope.session.accessToken)?.absoluteString
            }
            return series.cover
        }()
        if episode.movieImage != image {
            episode.movieImage = image
        }
        if episode.durationSecs != item.durationSecs {
            episode.durationSecs = item.durationSecs
        }
        if episode.rating != item.communityRating {
            episode.rating = item.communityRating
        }
        let airDate = item.premiereDate.map { String($0.prefix(10)) }
        if episode.airDate != airDate {
            episode.airDate = airDate
        }
        if episode.plot != item.overview {
            episode.plot = item.overview
        }
    }

    private func pruneJellyfinSeries(playlistId: UUID, seenSeries: Set<String>, seenEpisodes: Set<String>, fetched: Bool) {
        guard fetched else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = playlistId.uuidString
        let rows = (try? context.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        ))) ?? []
        for series in rows where series.id.contains("-jellyfin-") {
            if seenSeries.contains(series.id) {
                // The shell survives, but dropped episodes don't: delete them
                // explicitly (no cascade from a surviving parent).
                for episode in series.episodes where !seenEpisodes.contains(episode.id) {
                    context.delete(episode)
                }
            } else {
                // Episodes and cast cascade from the deleted series.
                context.delete(series)
            }
        }
        if context.hasChanges {
            try? context.save()
        }
    }

    /// Stable string→Int for the `streamId`/`seriesId` columns Jellyfin has no
    /// number for. FNV-1a, not `Hasher` — the latter is seeded per process, so
    /// ids would change on every launch and orphan user state. Only ever used
    /// as an opaque key: Jellyfin playback builds from `directURL`.
    nonisolated static func jellyfinHash(_ string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: Int64(bitPattern: hash & 0x7FFF_FFFF_FFFF_FFFF))
    }
}
