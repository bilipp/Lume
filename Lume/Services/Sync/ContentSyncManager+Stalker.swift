//
//  ContentSyncManager+Stalker.swift
//  Lume
//
//  The Stalker (Ministra) portal sync pipeline. Authenticates by MAC, then maps
//  the portal's `itv` / `vod` / `series` endpoints onto the same SwiftData models
//  the Xtream and m3u pipelines fill — so browsing, search, favorites and EPG all
//  work identically across source types.
//
//  Stalker hands out short-lived stream URLs, so the catalog stores each item's
//  `cmd` (in `directURL` / `directSource`) and the real URL is resolved at
//  playback time via `create_link` (see `StalkerStreamResolver`).
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// A positive `Int` stream id for a Stalker element. Stalker ids are numeric
    /// strings (`"123"`); fall back to a stable hash for the rare non-numeric id
    /// so element ids stay constant across re-syncs.
    private static func streamId(for stalkerId: String) -> Int {
        if let int = Int(stalkerId), int > 0 { return int }
        return M3UIdentity.numericId(for: stalkerId)
    }

    /// The Stalker pipeline: authenticate, then pull categories and content.
    func performStalkerSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?, full _: Bool = false) async throws {
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))

        await progress?.start(.authenticating)
        let profile = try await client.authenticate()
        updateStalkerPlaylistInfo(playlistId, profile: profile)
        await progress?.complete(.authenticating)

        // Fetch the category/genre lists once and reuse them to both persist the
        // categories and walk each one's content.
        await progress?.start(.movieCategories)
        let vodCategories = await (try? client.getCategories(type: "vod")) ?? []
        try syncStalkerCategories(vodCategories, type: .vod, playlistId: playlistId)
        await progress?.update(detail: "\(vodCategories.count) categories")
        await progress?.complete(.movieCategories)

        await progress?.start(.seriesCategories)
        let seriesCategories = await (try? client.getCategories(type: "series")) ?? []
        try syncStalkerCategories(seriesCategories, type: .series, playlistId: playlistId)
        await progress?.update(detail: "\(seriesCategories.count) categories")
        await progress?.complete(.seriesCategories)

        await progress?.start(.liveCategories)
        let genres = await (try? client.getLiveGenres()) ?? []
        try syncStalkerCategories(genres, type: .live, playlistId: playlistId)
        await progress?.update(detail: "\(genres.count) categories")
        await progress?.complete(.liveCategories)

        try await syncStalkerMovies(client: client, categories: vodCategories, playlistId: playlistId, progress: progress)
        try await Task.sleep(for: .seconds(1))
        try await syncStalkerSeries(client: client, categories: seriesCategories, playlistId: playlistId, progress: progress)
        try await Task.sleep(for: .seconds(1))
        try await syncStalkerChannels(client: client, playlistId: playlistId, progress: progress)

        markStalkerPlaylistUpdated(playlistId)
    }

    // MARK: - Categories

    private func syncStalkerCategories(_ cats: [StalkerCategory], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let lookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, cat) in cats.enumerated() where !cat.id.isEmpty {
            if let existing = lookup[cat.id] {
                existing.name = cat.title
                existing.sortOrder = index
                existing.lastRefreshed = Date()
            } else {
                let category = Category(apiId: cat.id, name: cat.title, parentId: 0, type: type, playlist: playlist)
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }
        try context.save()

        if !cats.isEmpty {
            pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: Set(cats.map(\.id)))
        }
    }

    // MARK: - Movies (vod)

    private func syncStalkerMovies(
        client: StalkerClient,
        categories: [StalkerCategory],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.movies)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        // Accumulate items across categories and save in fixed-size batches
        // (mirroring `syncStalkerChannels` and the Xtream/m3u pipelines).
        // Saving once per category produced one main-context merge — and the
        // browse-view `@Query` re-evaluation it triggers — per category, which
        // adds up on portals with many small categories.
        let batchSize = 2000
        var pending: [(item: StalkerVODItem, categoryId: String)] = []

        for category in categories where !category.id.isEmpty {
            try Task.checkCancellation()
            let items = await (try? client.getAllOrderedItems(type: "vod", categoryId: category.id)) ?? []
            guard !items.isEmpty else { continue }

            pending.append(contentsOf: items.map { (item: $0, categoryId: category.id) })
            while pending.count >= batchSize {
                let batch = Array(pending.prefix(batchSize))
                pending.removeFirst(batchSize)
                autoreleasepool {
                    imported += upsertStalkerMovies(
                        batch, playlistPrefix: playlistPrefix,
                        playlistId: playlistId, seenIds: &seenIds
                    )
                }
            }
            await progress?.update(detail: "\(imported + pending.count) items")
        }
        if !pending.isEmpty {
            autoreleasepool {
                imported += upsertStalkerMovies(
                    pending, playlistPrefix: playlistPrefix,
                    playlistId: playlistId, seenIds: &seenIds
                )
            }
        }

        if !seenIds.isEmpty {
            pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stalker: synced \(imported) movies")
        await progress?.complete(.movies)
    }

    /// Upserts one batch of VOD items (each carrying its category) on a fresh
    /// context and returns how many were imported.
    private func upsertStalkerMovies(
        _ items: [(item: StalkerVODItem, categoryId: String)],
        playlistPrefix: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.compactMap { entry -> String? in
            guard let stalkerId = entry.item.id else { return nil }
            return "\(playlistId.uuidString)-movie-\(Self.streamId(for: stalkerId))"
        }
        var existing: [String: Movie] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for movie in fetched {
            existing[movie.id] = movie
        }

        var imported = 0
        for (item, categoryId) in items {
            guard let stalkerId = item.id, let cmd = item.cmd else { continue }
            let streamId = Self.streamId(for: stalkerId)
            let movieId = "\(playlistId.uuidString)-movie-\(streamId)"
            seenIds.insert(movieId)

            let movie: Movie
            if let found = existing[movieId] {
                movie = found
            } else {
                movie = Movie(id: movieId, streamId: streamId, name: "")
                context.insert(movie)
            }
            movie.name = item.name ?? ""
            movie.streamIcon = item.screenshot
            movie.plot = item.description
            movie.releaseDate = item.year
            movie.rating = Double(item.rating ?? "") ?? movie.rating
            movie.categoryId = playlistPrefix + categoryId
            movie.directURL = cmd
            imported += 1
        }
        try? context.save()
        return imported
    }

    // MARK: - Series

    private func syncStalkerSeries(
        client: StalkerClient,
        categories: [StalkerCategory],
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.series)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"
        var seenIds = Set<String>()
        var imported = 0

        // Same cross-category batching as `syncStalkerMovies`, for the same
        // reason: one save (and main-context merge) per fixed-size batch
        // instead of one per category.
        let batchSize = 2000
        var pending: [(item: StalkerVODItem, categoryId: String)] = []

        for category in categories where !category.id.isEmpty {
            try Task.checkCancellation()
            let items = await (try? client.getAllOrderedItems(type: "series", categoryId: category.id)) ?? []
            guard !items.isEmpty else { continue }

            pending.append(contentsOf: items.map { (item: $0, categoryId: category.id) })
            while pending.count >= batchSize {
                let batch = Array(pending.prefix(batchSize))
                pending.removeFirst(batchSize)
                autoreleasepool {
                    imported += upsertStalkerSeries(
                        batch, playlistPrefix: playlistPrefix,
                        playlistId: playlistId, seenIds: &seenIds
                    )
                }
            }
            await progress?.update(detail: "\(imported + pending.count) items")
        }
        if !pending.isEmpty {
            autoreleasepool {
                imported += upsertStalkerSeries(
                    pending, playlistPrefix: playlistPrefix,
                    playlistId: playlistId, seenIds: &seenIds
                )
            }
        }

        if !seenIds.isEmpty {
            pruneStaleSeries(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stalker: synced \(imported) series")
        await progress?.complete(.series)
    }

    /// Upserts one batch of series items (each carrying its category) on a
    /// fresh context and returns how many were imported.
    private func upsertStalkerSeries(
        _ items: [(item: StalkerVODItem, categoryId: String)],
        playlistPrefix: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.compactMap { entry -> String? in
            guard let stalkerId = entry.item.id else { return nil }
            return "\(playlistId.uuidString)-series-\(Self.streamId(for: stalkerId))"
        }
        var existing: [String: Series] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for series in fetched {
            existing[series.id] = series
        }

        var imported = 0
        for (item, categoryId) in items {
            guard let stalkerId = item.id else { continue }
            let seriesId = Self.streamId(for: stalkerId)
            let id = "\(playlistId.uuidString)-series-\(seriesId)"
            seenIds.insert(id)

            let series: Series
            if let found = existing[id] {
                series = found
            } else {
                series = Series(id: id, seriesId: seriesId, name: "")
                context.insert(series)
            }
            series.name = item.name ?? ""
            series.cover = item.screenshot
            series.plot = item.description
            series.releaseDate = item.year
            series.categoryId = playlistPrefix + categoryId
            imported += 1
        }
        try? context.save()
        return imported
    }

    /// Fetches a Stalker series' episodes on demand (the series detail screen
    /// calls this through `fetchEpisodes`). Best-effort: the portal returns each
    /// episode as an ordered-list item carrying its own `cmd`, which is stored in
    /// `directSource` for playback-time `create_link` resolution. Portals that
    /// don't expose episodes this way yield an empty list, leaving the series
    /// browsable with no episodes rather than failing.
    func fetchStalkerEpisodes(seriesId: Int, seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
        let items = try await client.getAllOrderedItems(
            type: "series",
            categoryId: "*",
            movieId: String(seriesId),
            maxItems: 2000
        )
        var result: [ParsedEpisode] = []
        for (index, item) in items.enumerated() {
            guard let cmd = item.cmd else { continue }
            // Stalker series carry a flat episode list; use the provider order
            // (1-based) for the episode number and group everything under one
            // season, which is how most portals present a series.
            let episodeNumbers = item.seriesNumbers.isEmpty ? [index + 1] : item.seriesNumbers
            for episodeNum in episodeNumbers {
                let episodeKey = "\(item.id ?? "\(index)")-\(episodeNum)"
                result.append(ParsedEpisode(
                    id: "\(seriesElementId)-episode-\(episodeKey)",
                    episodeId: episodeKey,
                    title: item.name ?? "",
                    containerExtension: "mpegts",
                    seasonNum: 1,
                    episodeNum: episodeNum,
                    added: nil,
                    directSource: cmd,
                    durationSecs: nil,
                    movieImage: item.screenshot,
                    rating: nil,
                    airDate: item.year,
                    plot: item.description
                ))
            }
        }
        return result
    }

    // MARK: - Live channels (itv)

    private func syncStalkerChannels(
        client: StalkerClient,
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.liveStreams)
        let channels = try await client.getAllChannels()
        let totalCount = channels.count
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"
        var seenIds = Set<String>()
        // Local copy: ContentSyncManager.batchSize is file-private to the main
        // file, so it isn't visible from this extension.
        let batchSize = 2000

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, totalCount)
            autoreleasepool {
                upsertStalkerChannels(
                    Array(channels[batchStart ..< batchEnd]),
                    playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seenIds
                )
            }
            await progress?.update(
                detail: "\(batchEnd) of \(totalCount)",
                fraction: totalCount == 0 ? 1 : Double(batchEnd) / Double(totalCount)
            )
        }

        if !seenIds.isEmpty {
            pruneStaleLiveStreams(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stalker: synced \(totalCount) live channels")
        await progress?.complete(.liveStreams)
    }

    /// Upserts one batch of channels on a fresh context.
    private func upsertStalkerChannels(
        _ channels: [StalkerChannel],
        playlistPrefix: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = channels.compactMap { channel -> String? in
            guard let stalkerId = channel.id else { return nil }
            return "\(playlistId.uuidString)-live-\(Self.streamId(for: stalkerId))"
        }
        var existing: [String: LiveStream] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for stream in fetched {
            existing[stream.id] = stream
        }

        for channel in channels {
            guard let stalkerId = channel.id, let cmd = channel.cmd else { continue }
            let streamId = Self.streamId(for: stalkerId)
            let id = "\(playlistId.uuidString)-live-\(streamId)"
            seenIds.insert(id)

            let stream: LiveStream
            if let found = existing[id] {
                stream = found
            } else {
                stream = LiveStream(id: id, streamId: streamId, name: "")
                context.insert(stream)
            }
            stream.name = channel.name ?? ""
            stream.streamIcon = channel.logo
            stream.epgChannelId = channel.xmltvId
            stream.directURL = cmd
            stream.num = channel.number ?? 0
            if let genreId = channel.genreId {
                stream.categoryId = playlistPrefix + genreId
            }
        }
        try? context.save()
    }

    // MARK: - Playlist bookkeeping

    private func updateStalkerPlaylistInfo(_ playlistId: UUID, profile: StalkerProfile) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.userStatus = profile.status
        playlist.expDate = profile.expDate
        playlist.lastUpdated = Date()
        try? context.save()
    }

    private func markStalkerPlaylistUpdated(_ playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.lastUpdated = Date()
        try? context.save()
    }
}
