//
//  ContentSyncManager.swift
//  Lume
//
//  Manages content synchronization from Xtream API to SwiftData
//

import Foundation
import SwiftData
import OSLog

// MARK: - ContentSyncManager

actor ContentSyncManager {
    // MARK: - Properties

    private let modelContainer: ModelContainer
    private let xtreamClient: XtreamClient
    private var activeSyncTasks: [UUID: Task<Void, Error>] = [:]

    /// Number of items to process before saving and resetting the context.
    private let batchSize = 2000

    // MARK: - Initialization

    init(modelContainer: ModelContainer, xtreamClient: XtreamClient = XtreamClient()) {
        self.modelContainer = modelContainer
        self.xtreamClient = xtreamClient
    }

    // MARK: - Playlist Sync

    /// Performs a full sync of a playlist (categories and content)
    func syncPlaylist(_ playlist: Playlist, progress: SyncProgress? = nil, full: Bool = false) async throws {
        let playlistId = playlist.id

        guard activeSyncTasks[playlistId] == nil else {
            throw SyncError.syncInProgress
        }

        let task = Task {
            do {
                let statusContext = ModelContext(modelContainer)
                statusContext.autosaveEnabled = false
                guard let pl = try statusContext.fetch(
                    FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
                ).first else {
                    // The playlist isn't visible in this context's view of the
                    // store. Surface it as an error rather than silently logging
                    // a successful completion (which masks the real failure).
                    Logger.database.error("Sync aborted: playlist \(playlistId) not found in store")
                    throw SyncError.playlistNotFound
                }

                pl.syncStatus = .syncing
                try statusContext.save()

                await progress?.start(.authenticating)
                let authResponse = try await xtreamClient.getInfo(playlist: pl)
                updatePlaylistInfo(playlistId, with: authResponse)
                await progress?.complete(.authenticating)

                try await syncAllCategories(for: pl, playlistId: playlistId, progress: progress, full: full)

                try await syncMovies(for: pl, playlistId: playlistId, progress: progress)
                try await syncSeries(for: pl, playlistId: playlistId, progress: progress)
                try await syncLiveStreams(for: pl, playlistId: playlistId, progress: progress)

                let doneContext = ModelContext(modelContainer)
                doneContext.autosaveEnabled = false
                if let dpl = try doneContext.fetch(
                    FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
                ).first {
                    dpl.syncStatus = .idle
                    dpl.lastSyncDate = Date()
                    try doneContext.save()
                }
            } catch {
                let errContext = ModelContext(modelContainer)
                errContext.autosaveEnabled = false
                if let epl = try? errContext.fetch(
                    FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
                ).first {
                    epl.syncStatus = .error
                    try? errContext.save()
                }
                throw error
            }
        }

        activeSyncTasks[playlistId] = task

        do {
            try await task.value
        } catch {
            activeSyncTasks.removeValue(forKey: playlistId)
            throw error
        }

        activeSyncTasks.removeValue(forKey: playlistId)
        Logger.database.info("Completed sync for playlist \(playlistId)")
    }

    func syncAllCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil, full: Bool = false) async throws {
        Logger.database.info("Starting VOD category sync")
        await progress?.start(.movieCategories)
        try await syncVODCategories(for: playlist, playlistId: playlistId, progress: progress)
        await progress?.complete(.movieCategories)

        Logger.database.info("Starting Series category sync")
        await progress?.start(.seriesCategories)
        try await syncSeriesCategories(for: playlist, playlistId: playlistId, progress: progress)
        await progress?.complete(.seriesCategories)

        Logger.database.info("Starting Live TV category sync")
        await progress?.start(.liveCategories)
        try await syncLiveCategories(for: playlist, playlistId: playlistId, progress: progress)
        await progress?.complete(.liveCategories)
    }

    // MARK: - Category Sync

    private func syncVODCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamClient.getVODCategories(playlist: playlist)
        Logger.database.info("Fetched \(categories.count) VOD categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .vod, playlistId: playlistId)
    }

    private func syncSeriesCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamClient.getSeriesCategories(playlist: playlist)
        Logger.database.info("Fetched \(categories.count) Series categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .series, playlistId: playlistId)
    }

    private func syncLiveCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamClient.getLiveCategories(playlist: playlist)
        Logger.database.info("Fetched \(categories.count) Live categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .live, playlistId: playlistId)
    }

    private func syncCategories(_ dtos: [XtreamCategory], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let categoryLookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)

        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, categoryDTO) in dtos.enumerated() {
            if let existingCat = categoryLookup[categoryDTO.categoryId] {
                existingCat.name = categoryDTO.categoryName
                existingCat.parentId = categoryDTO.parentId ?? 0
                existingCat.sortOrder = index
                existingCat.lastRefreshed = Date()
            } else {
                let category = Category(
                    apiId: categoryDTO.categoryId,
                    name: categoryDTO.categoryName,
                    parentId: categoryDTO.parentId ?? 0,
                    type: type,
                    playlist: playlist
                )
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }

        try context.save()
    }

    // MARK: - Content Sync (Batched)

    /// Syncs movies in memory-bounded batches.
    ///
    /// Movies store their category as a plain `categoryId` foreign-key string —
    /// no SwiftData relationship — so each insert avoids the inverse-array
    /// updates that previously slowed sync as categories grew.
    func syncMovies(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        await progress?.start(.movies)
        let movieDTOs = try await xtreamClient.getVODStreams(playlist: playlist)
        let totalCount = movieDTOs.count
        Logger.database.info("Fetched \(totalCount) movies, syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = movieDTOs[batchStart..<batchEnd]

                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false

                for movieDTO in batch {
                    guard let streamId = movieDTO.streamId else { continue }
                    let movieId = "\(playlistId.uuidString)-movie-\(streamId)"

                    // @Attribute(.unique) on Movie.id: insert acts as upsert on save()
                    let movie = Movie(id: movieId, streamId: streamId, name: "")
                    movie.name = movieDTO.name ?? ""
                    movie.streamIcon = movieDTO.streamIcon
                    movie.rating = movieDTO.rating ?? 0
                    movie.rating5Based = movieDTO.rating5Based ?? 0
                    movie.added = movieDTO.added
                    movie.containerExtension = movieDTO.containerExtension
                    movie.tmdb = movieDTO.tmdb
                    movie.num = movieDTO.num ?? 0
                    movie.isAdult = movieDTO.isAdult ?? 0

                    if let catIdStr = movieDTO.categoryId {
                        movie.categoryId = playlistPrefix + catIdStr
                    }

                    if let tmdbString = movieDTO.tmdb, let tmdbInt = Int(tmdbString) {
                        movie.tmdbId = tmdbInt
                    }

                    context.insert(movie)
                }

                try context.save()
                Logger.database.info("Synced movies \(batchStart + 1)–\(batchEnd) of \(totalCount)")
            }
            await progress?.update(
                detail: "\(min(batchStart + batchSize, totalCount)) of \(totalCount)",
                fraction: totalCount == 0 ? 1 : Double(min(batchStart + batchSize, totalCount)) / Double(totalCount)
            )
        }

        Logger.database.info("Completed syncing \(totalCount) movies")
        await progress?.complete(.movies)
    }

    /// Syncs series in memory-bounded batches.
    func syncSeries(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        await progress?.start(.series)
        let seriesDTOs = try await xtreamClient.getSeries(playlist: playlist)
        let totalCount = seriesDTOs.count
        Logger.database.info("Fetched \(totalCount) series, syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = seriesDTOs[batchStart..<batchEnd]

                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false

                for seriesDTO in batch {
                    guard let seriesId = seriesDTO.seriesId else { continue }
                    let id = "\(playlistId.uuidString)-series-\(seriesId)"

                    let series = Series(id: id, seriesId: seriesId, name: "")
                    series.name = seriesDTO.name ?? ""
                    series.cover = seriesDTO.cover
                    series.plot = seriesDTO.plot
                    series.cast = seriesDTO.cast
                    series.director = seriesDTO.director
                    series.genre = seriesDTO.genre
                    series.releaseDate = seriesDTO.releaseDate
                    series.lastModified = seriesDTO.lastModified
                    series.rating = seriesDTO.rating
                    series.rating5Based = seriesDTO.rating5Based
                    series.tmdb = seriesDTO.tmdb
                    series.num = seriesDTO.num ?? 0

                    if let catIdStr = seriesDTO.categoryId {
                        series.categoryId = playlistPrefix + catIdStr
                    }

                    if let tmdbString = seriesDTO.tmdb, let tmdbInt = Int(tmdbString) {
                        series.tmdbId = tmdbInt
                    }

                    context.insert(series)
                }

                try context.save()
                Logger.database.info("Synced series \(batchStart + 1)–\(batchEnd) of \(totalCount)")
            }
            await progress?.update(
                detail: "\(min(batchStart + batchSize, totalCount)) of \(totalCount)",
                fraction: totalCount == 0 ? 1 : Double(min(batchStart + batchSize, totalCount)) / Double(totalCount)
            )
        }

        Logger.database.info("Completed syncing \(totalCount) series")
        await progress?.complete(.series)
    }

    /// Syncs episodes for a series
    func syncEpisodes(for series: Series, playlist: Playlist) async throws {
        let seriesInfo = try await xtreamClient.getSeriesInfo(playlist: playlist, seriesId: series.seriesId)
        guard let episodesDict = seriesInfo.episodes else { return }

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let seriesId = series.id
        guard let localSeries = try context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        ).first else { return }

        for (seasonKey, episodes) in episodesDict {
            guard let seasonNum = Int(seasonKey) else { continue }
            for episodeDTO in episodes {
                guard let episodeIdString = episodeDTO.id else { continue }
                let episodeId = "\(localSeries.id)-episode-\(episodeIdString)"

                let episode = Episode(
                    id: episodeId,
                    episodeId: episodeIdString,
                    title: "",
                    containerExtension: "mkv",
                    seasonNum: seasonNum,
                    episodeNum: episodeDTO.episodeNum ?? 0,
                    series: localSeries
                )

                episode.title = episodeDTO.title ?? ""
                episode.containerExtension = episodeDTO.containerExtension ?? "mkv"
                episode.seasonNum = seasonNum
                episode.episodeNum = episodeDTO.episodeNum ?? 0
                episode.added = episodeDTO.added
                episode.directSource = episodeDTO.directSource

                if let info = episodeDTO.info {
                    episode.durationSecs = info.durationSecs
                    episode.movieImage = info.movieImage
                    episode.rating = info.rating
                    episode.airDate = info.airDate
                }

                context.insert(episode)
            }
        }

        try context.save()
    }

    /// Syncs live streams in memory-bounded batches.
    func syncLiveStreams(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        await progress?.start(.liveStreams)
        let streamDTOs = try await xtreamClient.getLiveStreams(playlist: playlist)
        let totalCount = streamDTOs.count
        Logger.database.info("Fetched \(totalCount) live streams, syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = streamDTOs[batchStart..<batchEnd]

                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false

                for streamDTO in batch {
                    guard let streamId = streamDTO.streamId else { continue }
                    let id = "\(playlistId.uuidString)-live-\(streamId)"

                    let liveStream = LiveStream(id: id, streamId: streamId, name: "")
                    liveStream.name = streamDTO.name ?? ""
                    liveStream.streamIcon = streamDTO.streamIcon
                    liveStream.epgChannelId = streamDTO.epgChannelId
                    liveStream.added = streamDTO.added
                    liveStream.customSid = streamDTO.customSid
                    liveStream.tvArchive = streamDTO.tvArchive ?? 0
                    liveStream.tvArchiveDuration = streamDTO.tvArchiveDuration ?? 0
                    liveStream.isAdult = streamDTO.isAdult ?? 0
                    liveStream.num = streamDTO.num ?? 0

                    if let catIdStr = streamDTO.categoryId {
                        liveStream.categoryId = playlistPrefix + catIdStr
                    }

                    context.insert(liveStream)
                }

                try context.save()
                Logger.database.info("Synced streams \(batchStart + 1)–\(batchEnd) of \(totalCount)")
            }
            await progress?.update(
                detail: "\(min(batchStart + batchSize, totalCount)) of \(totalCount)",
                fraction: totalCount == 0 ? 1 : Double(min(batchStart + batchSize, totalCount)) / Double(totalCount)
            )
        }

        Logger.database.info("Completed syncing \(totalCount) live streams")
        await progress?.complete(.liveStreams)
    }

    // MARK: - Helper Methods

    private func updatePlaylistInfo(_ playlistId: UUID, with authResponse: XtreamAuthResponse) {
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

    private func buildExistingCategoryLookup(context: ModelContext, playlistId: UUID, type: CategoryType) -> [String: Category] {
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

// MARK: - Sync Error

enum SyncError: LocalizedError {
    case syncInProgress
    case playlistNotFound
    case invalidCredentials
    case networkError(Error)
    case databaseError(Error)

    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            return "A sync is already in progress for this playlist"
        case .playlistNotFound:
            return "The playlist could not be found"
        case .invalidCredentials:
            return "Invalid username or password"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .databaseError(let error):
            return "Database error: \(error.localizedDescription)"
        }
    }
}
