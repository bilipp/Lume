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
    /// in-process sync tracked in `activeSyncPlaylistIDs`, which cannot survive a
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

    /// Restores a playlist to `.idle` after an aborted sync, leaving whatever was
    /// already synced in place so the next attempt can pick up cleanly.
    func markPlaylistIdle(playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        if let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            playlist.syncStatus = .idle
            try? context.save()
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

    /// Copies the provider-owned fields from a movie DTO onto an existing or
    /// freshly-inserted `Movie`, leaving user state and TMDB enrichment intact.
    ///
    /// Every write is guarded by an inequality test. SwiftData marks a row dirty
    /// on *assignment*, not on change, so re-writing an identical value makes
    /// `save()` rewrite (and re-index) the whole row — the dominant cost of a
    /// re-sync where almost nothing changed.
    ///
    /// The guards must compare exactly what the unguarded assignment would have
    /// stored: `nil` and `""` are distinct values here (the provider sends both,
    /// and the lenient decoders preserve the difference), and the `Double`
    /// comparisons must stay exact. Any tolerance — treating empty as nil,
    /// rounding a rating — silently *stops* applying a legitimate provider
    /// update, which is harder to notice than the reverse.
    ///
    /// The cyclomatic-complexity opt-out below is deliberate: this is a flat
    /// field copy with one independent guard per provider field, not branching
    /// logic.
    func applyMovieFields(from dto: XtreamVODStream, to movie: Movie, playlistPrefix: String) { // swiftlint:disable:this cyclomatic_complexity
        let name = dto.name ?? ""
        if movie.name != name { movie.name = name }
        if movie.streamIcon != dto.streamIcon { movie.streamIcon = dto.streamIcon }
        let rating = dto.rating ?? 0
        if movie.rating != rating { movie.rating = rating }
        let rating5Based = dto.rating5Based ?? 0
        if movie.rating5Based != rating5Based { movie.rating5Based = rating5Based }
        if movie.added != dto.added { movie.added = dto.added }
        if movie.containerExtension != dto.containerExtension { movie.containerExtension = dto.containerExtension }
        if movie.tmdb != dto.tmdb { movie.tmdb = dto.tmdb }
        let num = dto.num ?? 0
        if movie.num != num { movie.num = num }
        let isAdult = dto.isAdult ?? 0
        if movie.isAdult != isAdult { movie.isAdult = isAdult }

        if let catIdStr = dto.categoryId {
            let categoryId = playlistPrefix + catIdStr
            if movie.categoryId != categoryId { movie.categoryId = categoryId }
        }
        if let tmdbString = dto.tmdb, let tmdbInt = Int(tmdbString), movie.tmdbId != tmdbInt {
            movie.tmdbId = tmdbInt
        }
    }

    /// Copies the provider-owned fields from a series DTO onto an existing or
    /// freshly-inserted `Series`, leaving user state and TMDB enrichment intact.
    ///
    /// Dirty-checked for the same reason, and under the same exactness rules, as
    /// `applyMovieFields`, including the complexity opt-out. `rating` and
    /// `rating5Based` are stored as the provider's own strings here, so no
    /// numeric normalisation applies — `"7"` and `"7.0"` are different values
    /// and must stay so.
    func applySeriesFields(from dto: XtreamSeries, to series: Series, playlistPrefix: String) { // swiftlint:disable:this cyclomatic_complexity
        let name = dto.name ?? ""
        if series.name != name { series.name = name }
        if series.cover != dto.cover { series.cover = dto.cover }
        if series.plot != dto.plot { series.plot = dto.plot }
        if series.cast != dto.cast { series.cast = dto.cast }
        if series.director != dto.director { series.director = dto.director }
        // Provider genre is the fallback only: it seeds an unset genre but never
        // overwrites one TMDB has supplied — TMDB is the primary source (see
        // `GenreParser.providerFallback`). The guard therefore compares the
        // computed result; comparing `dto.genre` would rewrite every
        // TMDB-enriched row on every sync and never settle.
        let genre = GenreParser.providerFallback(current: series.genre, provider: dto.genre)
        if series.genre != genre { series.genre = genre }
        if series.releaseDate != dto.releaseDate { series.releaseDate = dto.releaseDate }
        if series.lastModified != dto.lastModified { series.lastModified = dto.lastModified }
        if series.rating != dto.rating { series.rating = dto.rating }
        if series.rating5Based != dto.rating5Based { series.rating5Based = dto.rating5Based }
        if series.tmdb != dto.tmdb { series.tmdb = dto.tmdb }
        let num = dto.num ?? 0
        if series.num != num { series.num = num }

        if let catIdStr = dto.categoryId {
            let categoryId = playlistPrefix + catIdStr
            if series.categoryId != categoryId { series.categoryId = categoryId }
        }
        if let tmdbString = dto.tmdb, let tmdbInt = Int(tmdbString), series.tmdbId != tmdbInt {
            series.tmdbId = tmdbInt
        }
    }

    /// Copies the provider-owned fields from a live-stream DTO onto an existing
    /// or freshly-inserted `LiveStream`, leaving user state intact.
    ///
    /// Dirty-checked for the same reason, and under the same exactness rules, as
    /// `applyMovieFields`, including the complexity opt-out.
    func applyLiveStreamFields(from dto: XtreamLiveStream, to stream: LiveStream, playlistPrefix: String) { // swiftlint:disable:this cyclomatic_complexity
        let name = dto.name ?? ""
        if stream.name != name { stream.name = name }
        if stream.streamIcon != dto.streamIcon { stream.streamIcon = dto.streamIcon }
        if stream.epgChannelId != dto.epgChannelId { stream.epgChannelId = dto.epgChannelId }
        if stream.added != dto.added { stream.added = dto.added }
        if stream.customSid != dto.customSid { stream.customSid = dto.customSid }
        let tvArchive = dto.tvArchive ?? 0
        if stream.tvArchive != tvArchive { stream.tvArchive = tvArchive }
        let tvArchiveDuration = dto.tvArchiveDuration ?? 0
        if stream.tvArchiveDuration != tvArchiveDuration { stream.tvArchiveDuration = tvArchiveDuration }
        let isAdult = dto.isAdult ?? 0
        if stream.isAdult != isAdult { stream.isAdult = isAdult }
        let num = dto.num ?? 0
        if stream.num != num { stream.num = num }

        if let catIdStr = dto.categoryId {
            let categoryId = playlistPrefix + catIdStr
            if stream.categoryId != categoryId { stream.categoryId = categoryId }
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
