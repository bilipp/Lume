//
//  ContentSyncPruneTests.swift
//  LumeTests
//
//  The paged mark-and-sweep in ContentSyncManager+Prune: it deletes while the
//  deletions shift the fetch window underneath it, so every fixture here spans
//  several pages — a catalog that fits in one page passes even with the offset
//  arithmetic removed.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncPruneTests {
    /// Mirrors the sweep's page size; the fixtures below are sized against it.
    private let pageSize = 2000

    // MARK: - Fixtures

    private func insertMovies(_ range: Range<Int>, playlistId: UUID, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in range {
            context.insert(Movie(id: movieId(index, playlistId: playlistId), streamId: index, name: "Movie \(index)"))
        }
        try context.save()
    }

    private func movieId(_ index: Int, playlistId: UUID) -> String {
        "\(playlistId.uuidString)-movie-\(index)"
    }

    private func storedMovieIds(_ container: ModelContainer) throws -> Set<String> {
        try Set(ModelContext(container).fetch(FetchDescriptor<Movie>()).map(\.id))
    }

    private func vodDTOs(streamIds: [Int]) throws -> [XtreamVODStream] {
        let json = "[" + streamIds.map { "{\"stream_id\":\($0)}" }.joined(separator: ",") + "]"
        return try JSONDecoder().decode([XtreamVODStream].self, from: Data(json.utf8))
    }

    /// Mirrors what `syncMovies` accumulates while writing its batches — the
    /// sweep entry point takes that set, not the payload it came from.
    private func seenMovieIds(_ dtos: [XtreamVODStream], playlistId: UUID) -> Set<String> {
        Set(dtos.compactMap { dto in dto.streamId.map { movieId($0, playlistId: playlistId) } })
    }

    // MARK: - Paging

    @Test func `sweep removes every unseen row across page boundaries`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let total = pageSize * 2 + 500
        try insertMovies(0 ..< total, playlistId: playlistId, container: container)

        // Deletions scattered through every page: each page shrinks the table
        // under the next one's offset.
        let seen = (0 ..< total).filter { $0 % 3 != 0 }
        let seenIds = Set(seen.map { movieId($0, playlistId: playlistId) })

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)

        #expect(try storedMovieIds(container) == seenIds)
    }

    @Test func `sweep removes rows that fill whole pages`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< (pageSize * 2 + 250), playlistId: playlistId, container: container)

        // Nothing is seen, so every page deletes in full and the offset never
        // advances — the case where a naive `offset += pageSize` skips rows.
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleMovies(playlistId: playlistId, seenIds: [])

        #expect(try storedMovieIds(container).isEmpty)
    }

    @Test func `sweep leaves other playlists alone`() async throws {
        let container = try makeTestContainer()
        let swept = UUID()
        let untouched = UUID()
        try insertMovies(0 ..< (pageSize + 100), playlistId: swept, container: container)
        try insertMovies(0 ..< (pageSize + 100), playlistId: untouched, container: container)

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleMovies(playlistId: swept, seenIds: [])

        let remaining = try storedMovieIds(container)
        #expect(remaining.count == pageSize + 100)
        #expect(remaining.allSatisfy { $0.hasPrefix(untouched.uuidString) })
    }

    @Test func `surviving rows keep their user state`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< (pageSize + 100), playlistId: playlistId, container: container)

        let survivorId = movieId(pageSize + 50, playlistId: playlistId)
        do {
            let context = ModelContext(container)
            let survivor = try #require(
                try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == survivorId })).first
            )
            survivor.isFavorite = true
            survivor.watchProgress = 0.42
            try context.save()
        }

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleMovies(playlistId: playlistId, seenIds: [survivorId])

        let context = ModelContext(container)
        let survivors = try context.fetch(FetchDescriptor<Movie>())
        #expect(survivors.count == 1)
        #expect(survivors.first?.isFavorite == true)
        #expect(survivors.first?.watchProgress == 0.42)
    }

    @Test func `series sweep takes their episodes with them`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in 0 ..< (pageSize + 100) {
            let show = Series(id: "\(playlistId.uuidString)-series-\(index)", seriesId: index, name: "Show \(index)")
            context.insert(show)
            let episode = Episode(
                id: "\(playlistId.uuidString)-series-\(index)-episode-1",
                episodeId: "1",
                title: "Pilot",
                containerExtension: "mkv",
                seasonNum: 1,
                episodeNum: 1
            )
            context.insert(episode)
            show.episodes.append(episode)
        }
        try context.save()

        let keptId = "\(playlistId.uuidString)-series-7"
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleSeries(playlistId: playlistId, seenIds: [keptId])

        let check = ModelContext(container)
        #expect(try check.fetchCount(FetchDescriptor<Series>()) == 1)
        // Orphaned episodes would carry the watch progress of deleted shows.
        #expect(try check.fetchCount(FetchDescriptor<Episode>()) == 1)
        #expect(try check.fetch(FetchDescriptor<Episode>()).first?.series?.id == keptId)
    }

    // MARK: - m3u hashed sweep

    @Test func `the hashed sweep keeps exactly the rows the m3u import saw`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let total = pageSize * 2 + 500
        try insertMovies(0 ..< total, playlistId: playlistId, container: container)

        let seenIds = Set((0 ..< total).filter { $0 % 3 != 0 }.map { movieId($0, playlistId: playlistId) })
        let seenHashes = Set(seenIds.map { M3UIdentity.hash64($0) })

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleM3UMovies(playlistId: playlistId, seenHashes: seenHashes)

        #expect(try storedMovieIds(container) == seenIds)
    }

    @Test func `the hashed sweep spares episodes and series their import saw`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in 0 ..< (pageSize + 100) {
            let show = Series(id: "\(playlistId.uuidString)-series-\(index)", seriesId: index, name: "Show \(index)")
            context.insert(show)
            let episode = Episode(
                id: "\(playlistId.uuidString)-series-\(index)-episode-1",
                episodeId: "1",
                title: "Pilot",
                containerExtension: "mkv",
                seasonNum: 1,
                episodeNum: 1,
                series: show
            )
            context.insert(episode)
        }
        try context.save()

        let keptSeriesId = "\(playlistId.uuidString)-series-7"
        let keptEpisodeId = "\(keptSeriesId)-episode-1"
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneStaleM3UEpisodes(playlistId: playlistId, seenHashes: [M3UIdentity.hash64(keptEpisodeId)])
        await manager.pruneStaleM3USeries(playlistId: playlistId, seenHashes: [M3UIdentity.hash64(keptSeriesId)])

        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Series>()).map(\.id) == [keptSeriesId])
        #expect(try check.fetch(FetchDescriptor<Episode>()).map(\.id) == [keptEpisodeId])
    }

    // MARK: - Xtream payload sanity gate

    @Test func `a payload covering too little of the catalog is not swept`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        // XtreamList drops rows that fail to decode and only rethrows when all
        // of them do, so a mostly-malformed payload reaches the sweep as a
        // small non-empty array.
        let dtos = try vodDTOs(streamIds: Array(0 ..< 100))
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(
            playlistId: playlistId,
            seenIds: seenMovieIds(dtos, playlistId: playlistId),
            fetchedCount: dtos.count
        )

        #expect(try storedMovieIds(container).count == pageSize)
    }

    @Test func `a payload covering enough of the catalog still prunes`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        let dtos = try vodDTOs(streamIds: Array(0 ..< 500))
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(
            playlistId: playlistId,
            seenIds: seenMovieIds(dtos, playlistId: playlistId),
            fetchedCount: dtos.count
        )

        #expect(try storedMovieIds(container).count == 500)
    }

    @Test func `a payload whose rows carry no stream id is never swept`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        // The batch loop skips rows without a stream id, so a payload of them
        // accumulates no seen ids at all — the row count is what tells the gate
        // this was a real response and not an empty fetch.
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, seenIds: [], fetchedCount: 300)

        #expect(try storedMovieIds(container).count == pageSize)
    }

    @Test func `a catalog that really shrank is swept once the skips run out`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        // The coverage gate measures the payload against the STORED rows, and a
        // skipped sweep never reduces them — so a subscription that legitimately
        // shrinks below the floor would be refused forever and strand the dead
        // rows. The gate tolerates a bounded number of consecutive refusals and
        // then lets the sweep through.
        let dtos = try vodDTOs(streamIds: Array(0 ..< 100))
        let seen = seenMovieIds(dtos, playlistId: playlistId)
        let manager = ContentSyncManager(modelContainer: container)

        for _ in 0 ..< 2 {
            await manager.pruneMovies(playlistId: playlistId, seenIds: seen, fetchedCount: dtos.count)
            #expect(try storedMovieIds(container).count == pageSize)
        }

        await manager.pruneMovies(playlistId: playlistId, seenIds: seen, fetchedCount: dtos.count)
        #expect(try storedMovieIds(container).count == 100)
    }

    @Test func `a healthy sync clears the skip count`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        let manager = ContentSyncManager(modelContainer: container)
        let thin = try vodDTOs(streamIds: Array(0 ..< 100))
        await manager.pruneMovies(
            playlistId: playlistId,
            seenIds: seenMovieIds(thin, playlistId: playlistId),
            fetchedCount: thin.count
        )

        // A payload that covers the catalog resets the counter, so the next thin
        // one starts its tolerance over rather than tipping straight into a sweep.
        let healthy = try vodDTOs(streamIds: Array(0 ..< pageSize))
        await manager.pruneMovies(
            playlistId: playlistId,
            seenIds: seenMovieIds(healthy, playlistId: playlistId),
            fetchedCount: healthy.count
        )
        #expect(try storedMovieIds(container).count == pageSize)

        await manager.pruneMovies(
            playlistId: playlistId,
            seenIds: seenMovieIds(thin, playlistId: playlistId),
            fetchedCount: thin.count
        )
        #expect(try storedMovieIds(container).count == pageSize)
    }

    @Test func `an empty payload is never swept`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< 100, playlistId: playlistId, container: container)

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, seenIds: [], fetchedCount: 0)

        #expect(try storedMovieIds(container).count == 100)
    }
}

/// The sanity gate the m3u sweeps take before they delete anything. Its own
/// suite so `ContentSyncPruneTests` stays inside SwiftLint's type-body limit.
struct ContentSyncM3UPruneGateTests {
    private let pageSize = 2000

    // MARK: - Fixtures

    private func insertMovies(_ range: Range<Int>, playlistId: UUID, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in range {
            context.insert(Movie(id: movieId(index, playlistId: playlistId), streamId: index, name: "Movie \(index)"))
        }
        try context.save()
    }

    private func movieId(_ index: Int, playlistId: UUID) -> String {
        "\(playlistId.uuidString)-movie-\(index)"
    }

    private func storedMovieCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Movie>())
    }

    private func insertEpisodes(_ range: Range<Int>, playlistId: UUID, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in range {
            context.insert(Episode(
                id: episodeId(index, playlistId: playlistId),
                episodeId: "\(index)",
                title: "Episode \(index)",
                containerExtension: "mkv",
                seasonNum: 1,
                episodeNum: index
            ))
        }
        try context.save()
    }

    private func episodeId(_ index: Int, playlistId: UUID) -> String {
        "\(playlistId.uuidString)-series-1-episode-\(index)"
    }

    // MARK: - m3u payload sanity gate

    // The m3u file arrives `Transfer-Encoding: chunked` with no length to check
    // it against, so a cut connection yields a valid short playlist that imports
    // cleanly — and every row its missing tail would have named looks dropped.

    @Test func `a truncated m3u import does not sweep the rows it never reached`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        let seen = Set((0 ..< 100).map { M3UIdentity.hash64(movieId($0, playlistId: playlistId)) })
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, seenHashes: seen, importedCount: 100)

        #expect(try storedMovieCount(container) == pageSize)
    }

    @Test func `an m3u import covering enough of the catalog still prunes`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        let seen = Set((0 ..< 500).map { M3UIdentity.hash64(movieId($0, playlistId: playlistId)) })
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, seenHashes: seen, importedCount: 500)

        #expect(try storedMovieCount(container) == 500)
    }

    @Test func `an m3u import that produced nothing is never swept`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< 100, playlistId: playlistId, container: container)

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, seenHashes: [], importedCount: 0)

        #expect(try storedMovieCount(container) == 100)
    }

    @Test func `an m3u section that really shrank is swept once the skips run out`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertMovies(0 ..< pageSize, playlistId: playlistId, container: container)

        // A provider that genuinely dropped the section repeats the thin payload
        // every sync, so the bounded tolerance converges instead of stranding
        // the rows — the same escape hatch the Xtream gate has.
        let seen = Set((0 ..< 100).map { M3UIdentity.hash64(movieId($0, playlistId: playlistId)) })
        let manager = ContentSyncManager(modelContainer: container)

        for _ in 0 ..< 2 {
            await manager.pruneMovies(playlistId: playlistId, seenHashes: seen, importedCount: 100)
            #expect(try storedMovieCount(container) == pageSize)
        }

        await manager.pruneMovies(playlistId: playlistId, seenHashes: seen, importedCount: 100)
        #expect(try storedMovieCount(container) == 100)
    }

    @Test func `a truncated import does not sweep episodes either`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        try insertEpisodes(0 ..< pageSize, playlistId: playlistId, container: container)

        let seen = Set((0 ..< 50).map { M3UIdentity.hash64(episodeId($0, playlistId: playlistId)) })
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneEpisodes(playlistId: playlistId, seenHashes: seen, importedCount: 50)

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Episode>()) == pageSize)
    }

    @Test func `a truncated import does not sweep categories either`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let playlist = Playlist(name: "Provider", m3uURL: "http://example.com/get.php")
        context.insert(playlist)
        for index in 0 ..< 200 {
            context.insert(
                Lume.Category(apiId: "\(index)", name: "Group \(index)", parentId: 0, type: .vod, playlist: playlist)
            )
        }
        try context.save()

        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneCategories(
            playlistId: playlist.id, type: .vod, seenApiIds: ["0", "1", "2"], importedCount: 100
        )

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Lume.Category>()) == 200)
    }
}
