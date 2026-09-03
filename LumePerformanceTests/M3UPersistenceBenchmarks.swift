//
//  M3UPersistenceBenchmarks.swift
//  LumePerformanceTests
//
//  The store side of an m3u sync, which `PersistenceBenchmarks` never covered:
//  it measures the Xtream write shape, where episodes are fetched lazily per
//  series and so never reach the store in bulk. An m3u file names every episode
//  inline, so an import of the same provider writes ~1.48M `Episode` rows — the
//  kind the sync spends most of its time on, and the one with no benchmark at
//  all until now.
//
//  Split from PersistenceBenchmarks.swift rather than added to it: that file
//  sits at 421 lines against SwiftLint's 600-line limit and its class body at
//  420 against the 400-line type limit, and `swiftlint --strict` runs as an
//  error. The two suites share no state, so a sibling file costs nothing.
//
//  On-disk containers only, like its sibling: an in-memory store bypasses
//  SQLite, which is the cost being measured.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class M3UPersistenceBenchmarks: XCTestCase {
    /// Matches `ContentSyncManager.batchSize`; the whole point is to reproduce
    /// the sync's write shape, so it must track that constant.
    private let batchSize = 2000

    // The measured provider's m3u file, kind for kind, at one tenth scale. It
    // carries 1,719,199 entries — 56,858 live, 178,231 movies and 1,484,110
    // episodes across ~47.4k series — against 282,288 rows for the same account
    // over the Xtream API, which sends 47,568 series shells instead of their
    // episodes. A full pass would put one iteration into the tens of minutes,
    // so the mix (3% live / 11% movie / 86% episode) is kept and every count
    // divided by ten, which also lands the total in the same range as
    // `PersistenceBenchmarks`' Xtream catalog and makes the two comparable.
    private let liveStreamCount = 5686
    private let movieCount = 17823
    private let seriesCount = 4740
    private let episodeCount = 148_411

    // MARK: - Full catalog

    /// A cold m3u import: live channels, movies, and every episode with the
    /// series rows they hang off.
    ///
    /// One iteration rather than five, for the same reason as
    /// `testImportFullXtreamCatalog`: a pass writes ~177k rows through a real
    /// SQLite file. The comparison that matters is between commits, not between
    /// passes of one run.
    func testImportFullM3UCatalog() {
        measureStoreWork(metrics: [XCTClockMetric(), XCTMemoryMetric()], iterationCount: 1) { container in
            let playlistId = UUID()
            insertLiveStreams(count: liveStreamCount, playlistId: playlistId, container: container)
            insertMovies(count: movieCount, playlistId: playlistId, container: container)
            insertEpisodes(count: episodeCount, playlistId: playlistId, container: container)
        }
    }

    /// Re-importing that same file unchanged — the lever the m3u sync work is
    /// aimed at. There is no conditional GET against this provider, so every
    /// scheduled sync re-imports the whole file whether or not an entry moved,
    /// and what has to be cheap is the writing.
    ///
    /// Seeded outside the measured block, so this times the *second* pass:
    /// every row exists, every field written matches what is stored, and a
    /// batch that changes nothing must never reach `save()`.
    ///
    /// Two iterations for the same runtime reason as the cold import.
    func testReimportFullM3UCatalogUnchanged() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        insertLiveStreams(count: liveStreamCount, playlistId: playlistId, container: store.container)
        insertMovies(count: movieCount, playlistId: playlistId, container: store.container)
        insertEpisodes(count: episodeCount, playlistId: playlistId, container: store.container)

        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            insertLiveStreams(count: liveStreamCount, playlistId: playlistId, container: store.container)
            insertMovies(count: movieCount, playlistId: playlistId, container: store.container)
            insertEpisodes(count: episodeCount, playlistId: playlistId, container: store.container)
        }
    }

    // MARK: - Prune

    /// The episode sweep over a full m3u catalog with **nothing to delete** —
    /// what every re-sync pays purely to establish that no episode has gone
    /// away, over the most numerous kind in the store.
    ///
    /// Structured like `testPruneFullVODCatalogWithNoDeletions`, including the
    /// `Task.detached` + semaphore hand-off: `ContentSyncManager` is an actor,
    /// and a task that inherited this test's context could not start while the
    /// semaphore holds that context's thread. It drives the production sweep
    /// rather than a local copy, so a rewrite of the sweep is genuinely gated
    /// by this number.
    ///
    /// It calls `pruneStaleM3UEpisodes`, not the guarded `pruneEpisodes`
    /// wrapper: the coverage gate in front of that wrapper is a policy decision
    /// about whether to sweep at all, and it would also write this playlist's
    /// skip counter into `UserDefaults`. The seen-set is the `Set<UInt64>` of
    /// `M3UIdentity.hash64` the import actually builds, not a set of ids.
    ///
    /// Memory is measured alongside the clock because the sweep's cost is
    /// materialising rows, not deleting them.
    func testPruneFullEpisodeCatalogWithNoDeletions() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        insertEpisodes(count: episodeCount, playlistId: playlistId, container: store.container)

        let manager = ContentSyncManager(modelContainer: store.container)
        // Every id is "seen", so no row is deleted and every iteration sweeps
        // the same rows — without this the second pass would measure an empty
        // table.
        let seenHashes = Set((0 ..< episodeCount).map {
            M3UIdentity.hash64(episodeId(index: $0, count: episodeCount, playlistId: playlistId))
        })

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await manager.pruneStaleM3UEpisodes(playlistId: playlistId, seenHashes: seenHashes)
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    // MARK: - Store harness

    /// Runs `work` against a freshly created on-disk store on every iteration,
    /// with store setup and teardown outside the measured region. Same shape as
    /// `PersistenceBenchmarks.measureStoreWork`.
    private func measureStoreWork(
        metrics: [XCTMetric],
        iterationCount: Int = 5,
        _ work: (ModelContainer) -> Void
    ) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = iterationCount
        measure(metrics: metrics, options: options) {
            guard let store = try? PerfStore.makeOnDiskContainer() else {
                XCTFail("could not create the on-disk store")
                return
            }
            startMeasuring()
            work(store.container)
            stopMeasuring()
            PerfStore.destroy(directory: store.directory)
        }
    }

    // MARK: - Upsert loops

    // The three loops below are hand-written copies of `importLive`,
    // `importMovies` and `importEpisodes` — they cannot call them, since those
    // are driven by a streaming parse of a downloaded file. Each keeps the
    // production shape: one fresh, autosave-off `ModelContext` per batch, an
    // id-scoped fetch for existing rows, insert-or-update, and a `save()` that
    // only happens when something changed. They must be kept in step with
    // `ContentSyncManager+M3UFields.applyM3U*Fields` by hand, or the
    // unchanged-re-import benchmark stops tracking the path the app runs.

    private func insertLiveStreams(count: Int, playlistId: UUID, container: ModelContainer) {
        for batchStart in stride(from: 0, to: count, by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, count)
                let context = ModelContext(container)
                context.autosaveEnabled = false

                let ids = (batchStart ..< batchEnd).map { "\(playlistId.uuidString)-live-\($0)" }
                var existing: [String: LiveStream] = [:]
                existing.reserveCapacity(ids.count)
                let fetched = (try? context.fetch(
                    FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
                )) ?? []
                for stream in fetched {
                    existing[stream.id] = stream
                }

                for index in batchStart ..< batchEnd {
                    let id = "\(playlistId.uuidString)-live-\(index)"
                    let stream: LiveStream
                    if let found = existing[id] {
                        stream = found
                    } else {
                        stream = LiveStream(id: id, streamId: index, name: "")
                        context.insert(stream)
                        // Assigned only on insert, as the m3u import does: `num`
                        // is the entry's position in the file.
                        stream.num = index
                    }
                    applyLiveStreamFixture(index: index, playlistId: playlistId, to: stream)
                }
                if context.hasChanges { try? context.save() }
            }
        }
    }

    private func insertMovies(count: Int, playlistId: UUID, container: ModelContainer) {
        for batchStart in stride(from: 0, to: count, by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, count)
                let context = ModelContext(container)
                context.autosaveEnabled = false

                let ids = (batchStart ..< batchEnd).map { "\(playlistId.uuidString)-movie-\($0)" }
                var existing: [String: Movie] = [:]
                existing.reserveCapacity(ids.count)
                let fetched = (try? context.fetch(
                    FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
                )) ?? []
                for movie in fetched {
                    existing[movie.id] = movie
                }

                for index in batchStart ..< batchEnd {
                    let id = "\(playlistId.uuidString)-movie-\(index)"
                    let movie: Movie
                    if let found = existing[id] {
                        movie = found
                    } else {
                        movie = Movie(id: id, streamId: index, name: "")
                        context.insert(movie)
                        movie.num = index
                    }
                    applyMovieFixture(index: index, playlistId: playlistId, to: movie)
                }
                if context.hasChanges { try? context.save() }
            }
        }
    }

    /// The only loop here that writes two kinds: an m3u episode names its series
    /// inline, so the parent `Series` is created by the same pass. Episodes are
    /// laid out contiguously by series, the way they arrive in a provider file.
    private func insertEpisodes(count: Int, playlistId: UUID, container: ModelContainer) {
        for batchStart in stride(from: 0, to: count, by: batchSize) {
            autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                upsertEpisodes(
                    in: batchStart ..< min(batchStart + batchSize, count),
                    count: count,
                    playlistId: playlistId,
                    context: context
                )
                if context.hasChanges { try? context.save() }
            }
        }
    }

    private func upsertEpisodes(in range: Range<Int>, count: Int, playlistId: UUID, context: ModelContext) {
        let parentIndices = range.map { seriesIndex(forEpisode: $0, count: count) }
        let parentIds = parentIndices.map { seriesId(index: $0, playlistId: playlistId) }
        let ids = range.map { episodeId(index: $0, count: count, playlistId: playlistId) }

        let uniqueParentIds = Array(Set(parentIds))
        var shows: [String: Series] = [:]
        let fetchedShows = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { uniqueParentIds.contains($0.id) })
        )) ?? []
        for show in fetchedShows {
            shows[show.id] = show
        }

        var existing: [String: Episode] = [:]
        existing.reserveCapacity(ids.count)
        let fetched = (try? context.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for episode in fetched {
            existing[episode.id] = episode
        }

        // The series fields are hoisted out of the per-episode path exactly as
        // `importEpisodes` hoists them: one show can carry thousands of
        // episodes, all naming the same group title.
        var applied = Set<String>()
        for offset in 0 ..< range.count {
            let index = range.lowerBound + offset
            let show = series(
                id: parentIds[offset], index: parentIndices[offset], shows: &shows, context: context
            )
            if applied.insert(parentIds[offset]).inserted {
                applySeriesFixture(index: parentIndices[offset], playlistId: playlistId, to: show)
            }

            let id = ids[offset]
            let episode: Episode
            if let found = existing[id] {
                episode = found
            } else {
                episode = Episode(
                    id: id,
                    episodeId: "\(index)",
                    title: "",
                    containerExtension: "mkv",
                    seasonNum: index % 60 / 20 + 1,
                    episodeNum: index % 20 + 1,
                    series: show
                )
                context.insert(episode)
                existing[id] = episode
            }
            applyEpisodeFixture(index: index, to: episode)
        }
    }

    private func series(id: String, index: Int, shows: inout [String: Series], context: ModelContext) -> Series {
        if let found = shows[id] { return found }
        let show = Series(id: id, seriesId: index, name: "Series \(index)")
        // Assigned only on insert, as the m3u import does.
        show.num = index
        context.insert(show)
        shows[id] = show
        return show
    }

    // MARK: - Ids

    /// A provider file's episodes-per-series distribution has a long tail
    /// (median 12, p99 279); a flat division is enough here, because what the
    /// benchmark needs from the shape is only that a batch spans a handful of
    /// shows rather than one per row.
    private func seriesIndex(forEpisode index: Int, count: Int) -> Int {
        index * seriesCount / count
    }

    private func seriesId(index: Int, playlistId: UUID) -> String {
        "\(playlistId.uuidString)-series-\(index)"
    }

    /// The id shape the m3u import produces: an episode id carries its series
    /// id as a prefix, which is what puts it inside the sweep's playlist scope.
    private func episodeId(index: Int, count: Int, playlistId: UUID) -> String {
        "\(seriesId(index: seriesIndex(forEpisode: index, count: count), playlistId: playlistId))-episode-\(index)"
    }

    // MARK: - Field application

    // These stand in for `applyM3ULiveStreamFields` / `applyM3UMovieFields` /
    // `applyM3USeriesFields` / `applyM3UEpisodeFields`: one guarded assignment
    // per provider-owned field, over the m3u field set — which is narrower than
    // Xtream's, and carries `directURL` / `directSource` because an m3u entry is
    // a URL rather than a provider stream id. `num` is absent from all four: it
    // is assigned only on insert.

    private func applyLiveStreamFixture(index: Int, playlistId: UUID, to stream: LiveStream) {
        let name = "Channel \(index) HD"
        if stream.name != name { stream.name = name }
        let streamIcon = "https://example.invalid/logo/\(index).png"
        if stream.streamIcon != streamIcon { stream.streamIcon = streamIcon }
        // A third of the entries carry no tvg-id at all, and `nil` is distinct
        // from `""` here — the dirty check must not normalise them together.
        let epgChannelId: String? = index % 3 == 0 ? nil : "channel.\(index).xx"
        if stream.epgChannelId != epgChannelId { stream.epgChannelId = epgChannelId }
        let directURL = "https://example.invalid/user/pass/\(index)"
        if stream.directURL != directURL { stream.directURL = directURL }
        let categoryId = "\(playlistId.uuidString)-live-\(index % 900)"
        if stream.categoryId != categoryId { stream.categoryId = categoryId }
    }

    private func applyMovieFixture(index: Int, playlistId: UUID, to movie: Movie) {
        let name = "Movie \(index)"
        if movie.name != name { movie.name = name }
        let streamIcon = "https://example.invalid/p/\(index).jpg"
        if movie.streamIcon != streamIcon { movie.streamIcon = streamIcon }
        let directURL = "https://example.invalid/movie/user/pass/\(index).mkv"
        if movie.directURL != directURL { movie.directURL = directURL }
        if movie.containerExtension != "mkv" { movie.containerExtension = "mkv" }
        let categoryId = "\(playlistId.uuidString)-vod-\(index % 300)"
        if movie.categoryId != categoryId { movie.categoryId = categoryId }
    }

    private func applySeriesFixture(index: Int, playlistId: UUID, to series: Series) {
        let categoryId = "\(playlistId.uuidString)-series-\(index % 1544)"
        if series.categoryId != categoryId { series.categoryId = categoryId }
        // Seeded once and never overwritten: a later episode's logo must not
        // replace it, and TMDB enrichment owns it from then on.
        if series.cover == nil { series.cover = "https://example.invalid/c/\(index).jpg" }
    }

    private func applyEpisodeFixture(index: Int, to episode: Episode) {
        let title = "Episode \(index)"
        if episode.title != title { episode.title = title }
        let directSource = "https://example.invalid/series/user/pass/\(index).mkv"
        if episode.directSource != directSource { episode.directSource = directSource }
        let movieImage = "https://example.invalid/e/\(index).jpg"
        if episode.movieImage != movieImage { episode.movieImage = movieImage }
    }
}
