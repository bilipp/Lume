import Foundation
import OSLog
import SwiftData

// MARK: - Crash recovery

extension ContentSyncManager {
    /// Resets any playlist left in `.syncing` by a previous session that died
    /// mid-sync (tvOS suspends then terminates background apps aggressively, and
    /// a crash has the same effect).
    ///
    /// `.syncing` is a runtime-only state: the only thing that sets it is a live
    /// in-process task tracked in `activeSyncTasks`, which cannot survive a
    /// process launch. So a `.syncing` status observed at startup is by
    /// definition stale. Left untouched it wedges the playlist permanently —
    /// `AutoSync.shouldSync` skips anything already `.syncing`, so no further
    /// auto-sync ever fires and the blocking progress cover (driven by in-memory
    /// state) never reappears, while Settings keeps showing "Syncing" forever.
    ///
    /// Call once at launch, before the auto-sync gate reads playlist status.
    static func recoverInterruptedSyncs(in context: ModelContext) {
        let syncingRaw = SyncStatus.syncing.rawValue
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.syncStatusRaw == syncingRaw }
        )
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }

        for playlist in stuck {
            playlist.syncStatus = .idle
        }
        try? context.save()
        Logger.database.info("Recovered \(stuck.count) playlist(s) stuck in .syncing from a previous session")
    }
}

// MARK: - Helper Methods

extension ContentSyncManager {
    func markPlaylistError(playlistId: UUID) {
        let errContext = ModelContext(modelContainer)
        errContext.autosaveEnabled = false
        if let epl = try? errContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            epl.syncStatus = .error
            try? errContext.save()
        }
    }

    func updatePlaylistInfo(_ playlistId: UUID, with authResponse: XtreamAuthResponse) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        playlist.userStatus = authResponse.userInfo.status
        playlist.maxConnections = authResponse.userInfo.maxConnections
        playlist.activeConnections = authResponse.userInfo.activeCons
        playlist.expDate = authResponse.userInfo.expDate
        playlist.serverTimezone = authResponse.serverInfo.timezone
        playlist.lastUpdated = Date()
        try? context.save()
    }

    // MARK: - Existing-row lookups for in-place upsert

    // Content sync updates existing rows in place rather than inserting a fresh
    // model with the same unique id: an upsert replaces the whole stored row and
    // resets every field the sync doesn't set (isFavorite, watchProgress,
    // lastWatchedDate, isHidden, customOrder, favoriteOrder, TMDB enrichment…),
    // which previously wiped favorites and recently-watched on every sync. These
    // helpers fetch the rows for a batch, keyed by id, so the caller can mutate
    // the stored instance when present and insert only genuinely new items.

    func existingMovies(in batch: ArraySlice<XtreamVODStream>, playlistId: UUID, context: ModelContext) -> [String: Movie] {
        let ids = batch.compactMap { dto -> String? in
            guard let streamId = dto.streamId else { return nil }
            return "\(playlistId.uuidString)-movie-\(streamId)"
        }
        var lookup: [String: Movie] = [:]
        lookup.reserveCapacity(ids.count)
        for movie in (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? [] {
            lookup[movie.id] = movie
        }
        return lookup
    }

    func existingSeries(in batch: ArraySlice<XtreamSeries>, playlistId: UUID, context: ModelContext) -> [String: Series] {
        let ids = batch.compactMap { dto -> String? in
            guard let seriesId = dto.seriesId else { return nil }
            return "\(playlistId.uuidString)-series-\(seriesId)"
        }
        var lookup: [String: Series] = [:]
        lookup.reserveCapacity(ids.count)
        for series in (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? [] {
            lookup[series.id] = series
        }
        return lookup
    }

    func existingLiveStreams(in batch: ArraySlice<XtreamLiveStream>, playlistId: UUID, context: ModelContext) -> [String: LiveStream] {
        let ids = batch.compactMap { dto -> String? in
            guard let streamId = dto.streamId else { return nil }
            return "\(playlistId.uuidString)-live-\(streamId)"
        }
        var lookup: [String: LiveStream] = [:]
        lookup.reserveCapacity(ids.count)
        for stream in (try? context.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? [] {
            lookup[stream.id] = stream
        }
        return lookup
    }

    /// Copies the provider-owned fields from a series DTO onto an existing or
    /// freshly-inserted `Series`, leaving user state and TMDB enrichment intact.
    func applySeriesFields(from dto: XtreamSeries, to series: Series, playlistPrefix: String) {
        series.name = dto.name ?? ""
        series.cover = dto.cover
        series.plot = dto.plot
        series.cast = dto.cast
        series.director = dto.director
        series.genre = dto.genre
        series.releaseDate = dto.releaseDate
        series.lastModified = dto.lastModified
        series.rating = dto.rating
        series.rating5Based = dto.rating5Based
        series.tmdb = dto.tmdb
        series.num = dto.num ?? 0

        if let catIdStr = dto.categoryId {
            series.categoryId = playlistPrefix + catIdStr
        }
        if let tmdbString = dto.tmdb, let tmdbInt = Int(tmdbString) {
            series.tmdbId = tmdbInt
        }
    }

    func buildExistingCategoryLookup(context: ModelContext, playlistId: UUID, type: CategoryType) -> [String: Category] {
        let prefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let typeRaw = type.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.typeRaw == typeRaw }
        )
        guard let allCategories = try? context.fetch(descriptor) else { return [:] }
        var lookup: [String: Category] = [:]
        lookup.reserveCapacity(allCategories.count)
        for category in allCategories where category.id.hasPrefix(prefix) {
            lookup[category.apiId] = category
        }
        return lookup
    }
}
