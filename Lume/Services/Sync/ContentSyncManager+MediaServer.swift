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
    nonisolated struct JellyfinConnection {
        var server: URL
        var session: JellyfinSession
        var flavor: MediaServerFlavor
    }

    /// One library's import scope: everything the per-page upserts need beyond
    /// the items themselves. Bundled so the pipeline's helpers stay under the
    /// parameter-count lint.
    ///
    /// Not `private`: shared with `ContentSyncManager+MediaServerShows.swift`.
    nonisolated struct JellyfinViewScope {
        var connection: JellyfinConnection
        var playlistId: UUID
        var view: JellyfinLibrary
        var categoryId: String
        /// The category of every library of this kind in this sync, this one's
        /// included.
        var libraryCategoryIds: Set<String>

        /// Whether a row filed under `current` moves to this library. A title
        /// two libraries list stays in whichever holds it now: the libraries
        /// are read in parallel, so "the last one wins" would move it back and
        /// forth (and save it twice) on every sync.
        func claimsCategory(from current: String?) -> Bool {
            guard let current else { return true }
            return current != categoryId && !libraryCategoryIds.contains(current)
        }

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
        let movieScopes = scopes(connection, playlistId: playlistId, views: movieViews, type: .vod)
        let movies = try await walkJellyfinLibraries(movieScopes, progress: progress) { scope in
            try await self.syncJellyfinMovies(scope: scope)
        }
        let seenMovies = movies.values.reduce(into: Set<String>()) { $0.formUnion($1.seen) }
        let moviesComplete = movies.allRead && movies.values.allSatisfy(\.complete)
        pruneJellyfinMovies(playlistId: playlistId, flavor: flavor, seenIds: seenMovies, fetched: !movieViews.isEmpty && moviesComplete)
        await progress?.complete(.movies)

        await progress?.start(.series)
        let showScopes = scopes(connection, playlistId: playlistId, views: showViews, type: .series)
        let showWalks = try await walkJellyfinLibraries(showScopes, progress: progress) { scope in
            try await self.syncJellyfinShows(scope: scope)
        }
        var shows = showWalks.values.reduce(into: JellyfinShowsSeen()) { $0.merge($1) }
        shows.complete = shows.complete && showWalks.allRead
        pruneJellyfinSeries(playlistId: playlistId, flavor: flavor, seen: shows, fetched: !showViews.isEmpty && shows.complete)
        persistResolvesSourcesOnDemand(!shows.episodesFetchedPerShow.isEmpty, playlistId: playlistId)
        await progress?.complete(.series)

        markPlaylistUpdated(playlistId)
    }

    private func scopes(_ connection: JellyfinConnection, playlistId: UUID, views: [JellyfinLibrary], type: CategoryType) -> [JellyfinViewScope] {
        let categoryIds = views.map { "\(playlistId.uuidString)-\(type.rawValue)-\($0.id)" }
        let all = Set(categoryIds)
        return zip(views, categoryIds).map { view, categoryId in
            JellyfinViewScope(
                connection: connection, playlistId: playlistId, view: view,
                categoryId: categoryId, libraryCategoryIds: all
            )
        }
    }

    // MARK: - Libraries

    /// How many libraries are read at once. A server that builds its lists
    /// from upstream catalogues answers a page in up to ~12 s, and some list
    /// 28 libraries; read one after another that took 400 s warm and well
    /// past 10 minutes cold. Four in parallel is the same total work, and
    /// what such a server answered without a single slow or failed page.
    nonisolated static let concurrentLibraryWalks = 4

    /// What reading every library of one kind produced.
    nonisolated struct JellyfinLibraryWalks<Value: Sendable> {
        var values: [Value] = []
        /// False when a library failed outright: its rows were neither read
        /// nor confirmed gone, so the prune sweep for this kind must not run.
        var allRead = true
    }

    /// Reads each library with `walk`, `concurrentLibraryWalks` at a time.
    ///
    /// A library that fails is logged and skipped so the others still
    /// import; the kind is then marked not fully read. Only when every
    /// library failed does the sync fail, with the first error. A revoked
    /// session or a cancelled sync ends the whole walk at once.
    private func walkJellyfinLibraries<Value: Sendable>(
        _ scopes: [JellyfinViewScope],
        progress: SyncProgress?,
        walk: @escaping @Sendable (JellyfinViewScope) async throws -> Value
    ) async throws -> JellyfinLibraryWalks<Value> {
        var result = JellyfinLibraryWalks<Value>()
        var firstError: (any Error)?
        try await withThrowingTaskGroup(of: Result<Value, any Error>.self) { group in
            var pending = scopes.makeIterator()
            func start(_ scope: JellyfinViewScope) {
                group.addTask {
                    do {
                        return try await .success(walk(scope))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for _ in 0 ..< Self.concurrentLibraryWalks {
                guard let scope = pending.next() else { break }
                start(scope)
            }
            var finished = 0
            while let outcome = try await group.next() {
                finished += 1
                switch outcome {
                case let .success(value):
                    result.values.append(value)
                case let .failure(error):
                    if Self.endsJellyfinSync(error) {
                        throw error
                    }
                    result.allRead = false
                    firstError = firstError ?? error
                }
                await progress?.update(
                    detail: "\(finished) of \(scopes.count) libraries",
                    fraction: Double(finished) / Double(scopes.count)
                )
                if let scope = pending.next() {
                    start(scope)
                }
            }
        }
        if result.values.isEmpty, let firstError {
            throw firstError
        }
        return result
    }

    /// Whether a library failure ends the sync instead of just that library:
    /// cancellation, or a session the server no longer accepts (every other
    /// library would fail the same way).
    private nonisolated static func endsJellyfinSync(_ error: any Error) -> Bool {
        if Task.isCancelled || error is CancellationError {
            return true
        }
        switch error as? JellyfinError {
        case .unauthorized:
            return true
        case let .networkError(inner):
            return (inner as? URLError)?.code == .cancelled
        default:
            return false
        }
    }

    // MARK: - Paging

    /// How many items an open-ended library is read to (see
    /// `JellyfinTotalTracker`). Such a library is a ranked list — popular,
    /// trending, a streaming service's catalogue — that only ends when its
    /// upstream source runs dry, tens of thousands of items and hours of
    /// paging later. Its head is what anyone browses.
    nonisolated static let openEndedLibraryItemLimit = 500

    /// The outcome of one library walk.
    nonisolated struct JellyfinWalk {
        var fetched = 0
        /// False when an open-ended library failed part-way and the walk kept
        /// what it had: the items it never reached may still be listed, so
        /// the prune sweep for this kind must not run.
        var complete = true
    }

    /// Pages a recursive item query to exhaustion, handing each page to `body`.
    /// Shared by the movie, series and episode walks so the three differ only
    /// in what they do per page.
    ///
    /// A library whose total moves ahead with every page (see
    /// `JellyfinTotalTracker`) never reaches its total, so it stops at
    /// `openEndedLibraryItemLimit` instead, and a page that fails part-way
    /// through it ends that library rather than the whole sync. A library
    /// with a fixed total keeps the old behaviour: read to the end, and any
    /// failure aborts the sync with the catalog untouched.
    /// Not `private`: shared with `ContentSyncManager+MediaServerShows.swift`.
    func pageThroughJellyfinItems(
        types: [String],
        scope: JellyfinViewScope,
        unit: String,
        body: ([JellyfinItem]) -> Void
    ) async throws -> JellyfinWalk {
        var walk = JellyfinWalk()
        var tracker = JellyfinTotalTracker()
        let limit = Self.openEndedLibraryItemLimit
        while walk.fetched < tracker.total {
            try Task.checkCancellation()
            let page: JellyfinItemsResponse
            do {
                page = try await jellyfinClient.items(
                    server: scope.server, session: scope.session, parentId: scope.view.id, types: types,
                    startIndex: walk.fetched
                )
            } catch where tracker.isOpenEnded && !Task.isCancelled {
                let described = (error as? JellyfinError)?.logDescription ?? "request failed"
                let library = "\(scope.flavor.displayName) library \(scope.view.name)"
                Logger.database.error(
                    "\(library, privacy: .public) stopped at \(walk.fetched, privacy: .public) \(unit, privacy: .public) (\(described, privacy: .public)); keeping what it read"
                )
                walk.complete = false
                break
            }
            tracker.record(page)
            if !page.items.isEmpty {
                body(page.items)
            }
            walk.fetched += page.items.count
            if page.items.isEmpty {
                break
            }
            if tracker.isOpenEnded, walk.fetched >= limit {
                let library = "\(scope.flavor.displayName) library \(scope.view.name)"
                Logger.database.info(
                    "\(library, privacy: .public) has no fixed length; read its first \(walk.fetched, privacy: .public) \(unit, privacy: .public)"
                )
                break
            }
        }
        return walk
    }

    // MARK: - Session

    /// Stores the fresh session on the playlist so playback and artwork can
    /// authenticate without logging in again. A rotated or revoked token is
    /// simply replaced on the next sync, which always logs in first.
    /// Not `private`: the per-show episode fetch signs in again the same way.
    func persistJellyfinSession(_ session: JellyfinSession, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.jellyfinAccessToken = session.accessToken
        playlist.jellyfinUserId = session.userId
        try? context.save()
    }

    /// Records whether the server lists shows without the episodes under
    /// them, the sign of one that picks a source per item on demand. Written
    /// only when it changes, so an unchanged sync saves nothing.
    func persistResolvesSourcesOnDemand(_ value: Bool, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first, playlist.resolvesSourcesOnDemand != value else { return }
        playlist.resolvesSourcesOnDemand = value
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

    /// Reads one movie library, returning the ids it saw and whether it was
    /// read in full (see `JellyfinWalk.complete`).
    private func syncJellyfinMovies(scope: JellyfinViewScope) async throws -> (seen: Set<String>, complete: Bool) {
        var seen = Set<String>()
        let walk = try await pageThroughJellyfinItems(types: ["Movie"], scope: scope, unit: "movie(s)") { items in
            seen.formUnion(upsertJellyfinMovies(items, scope: scope))
        }
        Logger.database.info("\(scope.flavor.displayName, privacy: .public) movies synced for library \(scope.view.name, privacy: .public): \(walk.fetched, privacy: .public) item(s)")
        return (seen, walk.complete)
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
        if scope.claimsCategory(from: movie.categoryId) {
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
        CatalogAddedDate.assign(item.dateCreated, to: \.added, of: movie)
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
