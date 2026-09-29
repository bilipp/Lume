//
//  ContentSyncManager+XtreamContent.swift
//  Lume
//
//  The Xtream pipeline's three bulk content phases — movies, series and live
//  streams — each written in memory-bounded batches and then swept. Split out
//  of ContentSyncManager.swift, which sits at SwiftLint's type-length limit.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - Content Sync (Batched)

    /// Syncs movies in memory-bounded batches.
    ///
    /// Movies store their category as a plain `categoryId` foreign-key string —
    /// no SwiftData relationship — so each insert avoids the inverse-array
    /// updates that previously slowed sync as categories grew.
    func syncMovies(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress? = nil,
        reuseUnchanged: Bool = false
    ) async throws {
        let interval = Perf.begin(.syncMovies)
        defer { Perf.end(interval) }

        guard case .fetched(var movieDTOs, let digest) = try await beginXtreamPhase(
            .movies, playlistId: playlistId, reuseUnchanged: reuseUnchanged, progress: progress,
            fetch: { try await xtreamClient.getVODStreamsIfChanged(playlist: playlist, knownDigest: $0) }
        ) else { return }
        let totalCount = movieDTOs.count

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"

        // Accumulated as the batches are written so the sweep no longer needs
        // the DTO array, which can then be released before the sweep runs.
        var seenIds = Set<String>(minimumCapacity: totalCount)

        do {
            let upsertInterval = Perf.begin(.upsertMovies)
            defer { Perf.end(upsertInterval) }
            for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let batchEnd = min(batchStart + batchSize, totalCount)
                    let batch = movieDTOs[batchStart ..< batchEnd]

                    let context = ModelContext(modelContainer)
                    context.autosaveEnabled = false

                    // Update existing rows in place; see existingMovies for why.
                    let existing = existingMovies(in: batch, playlistId: playlistId, context: context)

                    for movieDTO in batch {
                        guard let streamId = movieDTO.streamId else { continue }
                        let movieId = "\(playlistId.uuidString)-movie-\(streamId)"
                        seenIds.insert(movieId)

                        let movie: Movie
                        if let found = existing[movieId] {
                            movie = found
                        } else {
                            movie = Movie(id: movieId, streamId: streamId, name: "")
                            context.insert(movie)
                        }
                        applyMovieFields(from: movieDTO, to: movie, playlistPrefix: playlistPrefix)
                    }

                    // A re-sync where the provider changed nothing leaves the
                    // context clean (see applyMovieFields): skip save() entirely
                    // rather than pay a full transaction for zero rows.
                    if context.hasChanges {
                        try context.save()
                    }
                    Logger.database.info("Synced movies \(batchStart + 1)–\(batchEnd) of \(totalCount)")
                }
                await progress?.update(
                    detail: "\(min(batchStart + batchSize, totalCount)) of \(totalCount)",
                    fraction: totalCount == 0 ? 1 : Double(min(batchStart + batchSize, totalCount)) / Double(totalCount)
                )
            }
        }

        // The decoded payload is ~178k rows on a large provider; drop it before
        // the sweep starts allocating pages of its own.
        movieDTOs = []

        // Remove movies the provider has dropped (see pruneMovies for the guard).
        await finishXtreamPhase(.movies, payload: (digest, totalCount), playlistId: playlistId, progress: progress) {
            pruneMovies(playlistId: playlistId, seenIds: seenIds, fetchedCount: totalCount)
        }
    }

    /// Syncs series in memory-bounded batches.
    func syncSeries(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress? = nil,
        reuseUnchanged: Bool = false
    ) async throws {
        let interval = Perf.begin(.syncSeries)
        defer { Perf.end(interval) }

        guard case .fetched(var seriesDTOs, let digest) = try await beginXtreamPhase(
            .series, playlistId: playlistId, reuseUnchanged: reuseUnchanged, progress: progress,
            fetch: { try await xtreamClient.getSeriesIfChanged(playlist: playlist, knownDigest: $0) }
        ) else { return }
        let totalCount = seriesDTOs.count

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"

        // Accumulated as the batches are written so the sweep no longer needs
        // the DTO array, which can then be released before the sweep runs.
        var seenIds = Set<String>(minimumCapacity: totalCount)

        do {
            let upsertInterval = Perf.begin(.upsertSeries)
            defer { Perf.end(upsertInterval) }
            for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let batchEnd = min(batchStart + batchSize, totalCount)
                    let batch = seriesDTOs[batchStart ..< batchEnd]

                    let context = ModelContext(modelContainer)
                    context.autosaveEnabled = false

                    // Update existing rows in place; see existingSeries for why.
                    let existing = existingSeries(in: batch, playlistId: playlistId, context: context)

                    for seriesDTO in batch {
                        guard let seriesId = seriesDTO.seriesId else { continue }
                        let id = "\(playlistId.uuidString)-series-\(seriesId)"
                        seenIds.insert(id)

                        let series: Series
                        if let found = existing[id] {
                            series = found
                        } else {
                            series = Series(id: id, seriesId: seriesId, name: "")
                            context.insert(series)
                        }
                        applySeriesFields(from: seriesDTO, to: series, playlistPrefix: playlistPrefix)
                    }

                    // A re-sync where the provider changed nothing leaves the
                    // context clean (see applySeriesFields): skip save() entirely
                    // rather than pay a full transaction for zero rows.
                    if context.hasChanges {
                        try context.save()
                    }
                    Logger.database.info("Synced series \(batchStart + 1)–\(batchEnd) of \(totalCount)")
                }
                await progress?.update(
                    detail: "\(min(batchStart + batchSize, totalCount)) of \(totalCount)",
                    fraction: totalCount == 0 ? 1 : Double(min(batchStart + batchSize, totalCount)) / Double(totalCount)
                )
            }
        }

        // Series rows carry ~1 KB of plot/cast text each; drop the payload
        // before the sweep starts allocating pages of its own.
        seriesDTOs = []

        // Remove series the provider has dropped (episodes/cast cascade).
        await finishXtreamPhase(.series, payload: (digest, totalCount), playlistId: playlistId, progress: progress) {
            pruneSeries(playlistId: playlistId, seenIds: seenIds, fetchedCount: totalCount)
        }
    }

    /// Syncs live streams in memory-bounded batches.
    func syncLiveStreams(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress? = nil,
        reuseUnchanged: Bool = false
    ) async throws {
        let interval = Perf.begin(.syncLiveStreams)
        defer { Perf.end(interval) }

        guard case .fetched(var streamDTOs, let digest) = try await beginXtreamPhase(
            .live, playlistId: playlistId, reuseUnchanged: reuseUnchanged, progress: progress,
            fetch: { try await xtreamClient.getLiveStreamsIfChanged(playlist: playlist, knownDigest: $0) }
        ) else { return }
        let totalCount = streamDTOs.count

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"

        // Accumulated as the batches are written so the sweep no longer needs
        // the DTO array, which can then be released before the sweep runs.
        var seenIds = Set<String>(minimumCapacity: totalCount)

        do {
            let upsertInterval = Perf.begin(.upsertLiveStreams)
            defer { Perf.end(upsertInterval) }
            for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let batchEnd = min(batchStart + batchSize, totalCount)
                    let batch = streamDTOs[batchStart ..< batchEnd]

                    let context = ModelContext(modelContainer)
                    context.autosaveEnabled = false

                    // Update existing rows in place; see existingLiveStreams for why.
                    let existing = existingLiveStreams(in: batch, playlistId: playlistId, context: context)

                    for streamDTO in batch {
                        guard let streamId = streamDTO.streamId else { continue }
                        let id = "\(playlistId.uuidString)-live-\(streamId)"
                        seenIds.insert(id)

                        let liveStream: LiveStream
                        if let found = existing[id] {
                            liveStream = found
                        } else {
                            liveStream = LiveStream(id: id, streamId: streamId, name: "")
                            context.insert(liveStream)
                        }
                        applyLiveStreamFields(from: streamDTO, to: liveStream, playlistPrefix: playlistPrefix)
                    }

                    // A re-sync where the provider changed nothing leaves the
                    // context clean (see applyLiveStreamFields): skip save() entirely
                    // rather than pay a full transaction for zero rows.
                    if context.hasChanges {
                        try context.save()
                    }
                    Logger.database.info("Synced streams \(batchStart + 1)–\(batchEnd) of \(totalCount)")
                }
                await progress?.update(
                    detail: "\(min(batchStart + batchSize, totalCount)) of \(totalCount)",
                    fraction: totalCount == 0 ? 1 : Double(min(batchStart + batchSize, totalCount)) / Double(totalCount)
                )
            }
        }

        // Drop the payload before the sweep starts allocating pages of its own.
        streamDTOs = []

        // Remove live channels the provider has dropped.
        await finishXtreamPhase(.live, payload: (digest, totalCount), playlistId: playlistId, progress: progress) {
            pruneLiveStreams(playlistId: playlistId, seenIds: seenIds, fetchedCount: totalCount)
        }
    }
}
