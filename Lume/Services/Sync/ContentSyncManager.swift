//
//  ContentSyncManager.swift
//  Lume
//
//  Manages content synchronization from Xtream API to SwiftData
//

import Foundation
import OSLog
import SwiftData

// MARK: - ContentSyncManager

actor ContentSyncManager {
    // MARK: - Properties

    let modelContainer: ModelContainer
    let xtreamClient: XtreamClient
    private var activeSyncTasks: [UUID: Task<Void, Error>] = [:]

    /// Number of items to process before saving and resetting the context.
    private let batchSize = 2000
    private let epgBatchSize = 500

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
                try await performSync(playlistId: playlistId, progress: progress, full: full)
            } catch {
                markPlaylistError(playlistId: playlistId)
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

    private func performSync(playlistId: UUID, progress: SyncProgress?, full: Bool) async throws {
        let statusContext = ModelContext(modelContainer)
        statusContext.autosaveEnabled = false
        guard let playlist = try statusContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else {
            Logger.database.error("Sync aborted: playlist \(playlistId) not found in store")
            throw SyncError.playlistNotFound
        }

        playlist.syncStatus = .syncing
        try statusContext.save()

        await progress?.start(.authenticating)
        let authResponse = try await xtreamClient.getInfo(playlist: playlist)
        updatePlaylistInfo(playlistId, with: authResponse)
        await progress?.complete(.authenticating)

        try await syncAllCategories(for: playlist, playlistId: playlistId, progress: progress, full: full)

        try await syncMovies(for: playlist, playlistId: playlistId, progress: progress)
        try await Task.sleep(for: .seconds(2))
        try await syncSeries(for: playlist, playlistId: playlistId, progress: progress)
        try await Task.sleep(for: .seconds(2))
        try await syncLiveStreams(for: playlist, playlistId: playlistId, progress: progress)
        try await syncEPG(for: playlist, playlistId: playlistId, progress: progress)

        let doneContext = ModelContext(modelContainer)
        doneContext.autosaveEnabled = false
        if let dpl = try doneContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            dpl.syncStatus = .idle
            dpl.lastSyncDate = Date()
            try doneContext.save()
        }
    }

    func syncAllCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil, full _: Bool = false) async throws {
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
        // swiftformat:disable:next redundantSelf
        Logger.database.info("Fetched \(totalCount) movies, syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = movieDTOs[batchStart ..< batchEnd]

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
        // swiftformat:disable:next redundantSelf
        Logger.database.info("Fetched \(totalCount) series, syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = seriesDTOs[batchStart ..< batchEnd]

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
        // swiftformat:disable:next redundantSelf
        Logger.database.info("Fetched \(totalCount) live streams, syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try autoreleasepool {
                let batchEnd = min(batchStart + batchSize, totalCount)
                let batch = streamDTOs[batchStart ..< batchEnd]

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

    /// Syncs EPG data for all live streams using a single XMLTV
    /// (`/xmltv.php`) request, then processes results in memory-bounded batches.
    private func syncEPG(for playlist: Playlist, playlistId _: UUID, progress: SyncProgress? = nil) async throws {
        await progress?.start(.epg)

        var byStreamID: [Int: String] = [:]
        var byEPGChannelID: [String: [String]] = [:]
        do {
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            let allStreams = try context.fetch(FetchDescriptor<LiveStream>())

            guard !allStreams.isEmpty else {
                Logger.database.info("No live streams found, skipping EPG sync")
                await progress?.complete(.epg)
                return
            }

            for stream in allStreams {
                byStreamID[stream.streamId] = stream.id
                if let epgId = stream.epgChannelId {
                    byEPGChannelID[epgId, default: []].append(stream.id)
                }
            }
        }

        Logger.database.info("Fetching XMLTV EPG data")
        let epgEntries = try await xtreamClient.getXMLTV(playlist: playlist)
        let totalEntries = epgEntries.count
        Logger.database.info("Fetched \(totalEntries) EPG entries")

        var streamEPG: [String: [XtreamDataTableEPG]] = [:]
        for entry in epgEntries {
            let streamIDs = EPGHelper.match(entry, byStreamID: byStreamID, byEPGChannelID: byEPGChannelID)
            for sid in streamIDs {
                streamEPG[sid, default: []].append(entry)
            }
        }

        byStreamID = [:]
        byEPGChannelID = [:]

        let totalCount = streamEPG.count
        Logger.database.info("Matched EPG for \(totalCount) live streams")
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let matchedStreamIDs = Array(streamEPG.keys)

        try await processEPGBatches(
            streamIDs: matchedStreamIDs,
            streamEPG: streamEPG,
            totalCount: streamEPG.count,
            totalEntries: totalEntries,
            progress: progress
        )
    }

    private func processEPGBatches(
        streamIDs: [String],
        streamEPG: [String: [XtreamDataTableEPG]],
        totalCount: Int,
        totalEntries: Int,
        progress: SyncProgress?
    ) async throws {
        var processedCount = 0

        for batchStart in stride(from: 0, to: streamIDs.count, by: epgBatchSize) {
            let batchEnd = min(batchStart + epgBatchSize, streamIDs.count)

            try autoreleasepool {
                let batchIDs = streamIDs[batchStart ..< batchEnd]
                let batchContext = ModelContext(modelContainer)
                batchContext.autosaveEnabled = false

                for streamID in batchIDs {
                    guard
                        let entries = streamEPG[streamID],
                        let stream = try batchContext.fetch(FetchDescriptor<LiveStream>(
                            predicate: #Predicate { $0.id == streamID }
                        )).first
                    else { continue }

                    for existing in stream.epgListings {
                        batchContext.delete(existing)
                    }
                    stream.epgListings.removeAll()

                    for dto in entries {
                        guard
                            let startDate = EPGHelper.parseEPGDate(dto.start ?? dto.startTimestamp),
                            let endDate = EPGHelper.parseEPGDate(dto.end ?? dto.endTimestamp),
                            let title = dto.title,
                            !title.isEmpty
                        else { continue }

                        let listingId = "\(stream.id)-epg-\(Int(startDate.timeIntervalSince1970))"
                        let listing = EPGListing(
                            id: listingId,
                            epgId: stream.epgChannelId ?? "",
                            title: title,
                            listingDescription: dto.description ?? "",
                            start: startDate,
                            end: endDate,
                            liveStream: stream
                        )
                        batchContext.insert(listing)
                    }
                }

                try batchContext.save()
            }

            processedCount += batchEnd - batchStart
            Logger.database.info("Processed EPG for \(processedCount) of \(totalCount) matched streams")
            await progress?.update(
                detail: "\(min(processedCount, totalCount)) of \(totalCount)",
                fraction: totalCount == 0 ? 1 : Double(min(processedCount, totalCount)) / Double(totalCount)
            )
        }

        Logger.database.info("Completed EPG sync (\(totalEntries) entries for \(totalCount) streams)")
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
            "A sync is already in progress for this playlist"
        case .playlistNotFound:
            "The playlist could not be found"
        case .invalidCredentials:
            "Invalid username or password"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .databaseError(error):
            "Database error: \(error.localizedDescription)"
        }
    }
}

// MARK: - EPG Helpers

private enum EPGHelper {
    static func match(
        _ entry: XtreamDataTableEPG,
        byStreamID: [Int: String],
        byEPGChannelID: [String: [String]]
    ) -> [String] {
        if let sidString = entry.streamId ?? entry.epgId ?? entry.id,
           let sidInt = Int(sidString),
           let sid = byStreamID[sidInt]
        {
            return [sid]
        }
        if let cid = entry.channelId, let sids = byEPGChannelID[cid] {
            return sids
        }
        return []
    }

    static func parseEPGDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let unix = TimeInterval(value) {
            return Date(timeIntervalSince1970: unix)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
