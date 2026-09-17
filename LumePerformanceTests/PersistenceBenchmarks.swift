//
//  PersistenceBenchmarks.swift
//  LumePerformanceTests
//
//  Tier A, store edition: the SwiftData writes users actually wait on.
//
//  Profiling a 600k-entry playlist showed the import — not the download — owning
//  the multi-minute wait, and that a no-change re-sync costs nearly as much as a
//  first one (because the upsert lookup runs regardless). Both properties are
//  pinned here.
//
//  These run against an **on-disk** container. An in-memory store bypasses
//  SQLite, which is precisely the cost being measured.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class PersistenceBenchmarks: XCTestCase {
    /// Matches `ContentSyncManager.batchSize`; the whole point is to reproduce
    /// the sync's write shape, so it must track that constant.
    private let batchSize = 2000

    // The measured provider, row for row: 282,288 rows across the three kinds,
    // which is the catalog that takes ~4 minutes to sync on an Apple TV 4K.
    // Kept literal rather than rounded so a run here is comparable to a device
    // trace of that provider.
    private let catalogLiveStreamCount = 56713
    private let catalogMovieCount = 178_007
    private let catalogSeriesCount = 47568

    // MARK: - Insert

    /// Cold insert of 20k movies through the sync's context-per-batch pattern.
    /// Measures wall clock *and* storage: a regression that stops resetting the
    /// context per batch shows up as memory, one that writes more per row shows
    /// up as bytes.
    func testInsert20kMoviesOnDisk() {
        measureStoreWork(metrics: [XCTClockMetric(), XCTMemoryMetric()]) { container in
            let playlistId = UUID()
            insertMovies(count: 20000, playlistId: playlistId, container: container)
        }
    }

    /// Re-importing an unchanged catalog. Users hit this on every scheduled sync,
    /// and it was measured at nearly the cost of a first import — so it gets its
    /// own baseline rather than being assumed cheap.
    func testReimport20kUnchangedMovies() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        // Seed outside the measured block: we are timing the *second* pass.
        insertMovies(count: 20000, playlistId: playlistId, container: store.container)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            insertMovies(count: 20000, playlistId: playlistId, container: store.container)
        }
    }

    /// Cold insert of 20k series. Series rows are the heaviest of the three
    /// kinds — ~1 KB of plot/cast/director text each — and they route genre
    /// through `GenreParser.providerFallback`, so their per-row cost is not the
    /// movie number.
    func testInsert20kSeriesOnDisk() {
        measureStoreWork(metrics: [XCTClockMetric(), XCTMemoryMetric()]) { container in
            let playlistId = UUID()
            insertSeries(count: 20000, playlistId: playlistId, container: container)
        }
    }

    /// Cold insert of 20k live channels — the narrowest rows of the three kinds,
    /// and the phase that runs first on a fresh playlist.
    func testInsert20kLiveStreamsOnDisk() {
        measureStoreWork(metrics: [XCTClockMetric(), XCTMemoryMetric()]) { container in
            let playlistId = UUID()
            insertLiveStreams(count: 20000, playlistId: playlistId, container: container)
        }
    }

    /// The guide-ingest write path: `EPGSyncManager` accumulates listings on one
    /// context and saves every 10k to limit main-context merges. 60k listings is
    /// a modest real guide.
    func testInsert60kEPGListings() {
        measureStoreWork(metrics: [XCTClockMetric(), XCTMemoryMetric()]) { container in
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let epoch = Date(timeIntervalSince1970: 1_800_000_000)
            var pending = 0
            for index in 0 ..< 60000 {
                let start = epoch.addingTimeInterval(Double(index % 300) * 1800)
                context.insert(EPGListing(
                    id: "ch\(index / 300)-\(Int(start.timeIntervalSince1970))-\(index)",
                    channelId: "ch\(index / 300)",
                    title: "Programme \(index)",
                    listingDescription: "A synthetic description for programme \(index).",
                    start: start,
                    end: start.addingTimeInterval(1800)
                ))
                pending += 1
                // Mirrors EPGSyncManager.saveThreshold.
                if pending >= 10000 {
                    try? context.save()
                    pending = 0
                }
            }
            if pending > 0 {
                try? context.save()
            }
        }
    }

    // MARK: - Full catalog

    /// The whole measured provider in one store: 56,713 live channels, 178,007
    /// movies and 47,568 series. The per-kind benchmarks above each start from
    /// an empty database, which hides the part that actually hurts — later
    /// batches upserting against a store that already holds a quarter of a
    /// million rows.
    ///
    /// One iteration rather than five: a pass writes 282k rows through a real
    /// SQLite file, so the default would put this single test into the tens of
    /// minutes. The comparison that matters here is between commits, not
    /// between passes of one run.
    func testImportFullXtreamCatalog() {
        measureStoreWork(metrics: [XCTClockMetric(), XCTMemoryMetric()], iterationCount: 1) { container in
            let playlistId = UUID()
            insertLiveStreams(count: catalogLiveStreamCount, playlistId: playlistId, container: container)
            insertMovies(count: catalogMovieCount, playlistId: playlistId, container: container)
            insertSeries(count: catalogSeriesCount, playlistId: playlistId, container: container)
        }
    }

    /// Re-importing that same catalog unchanged — the scheduled-sync path, and
    /// the one the sync-performance work is aimed at. Seeded outside the
    /// measured block, so this times the second pass: every row already exists,
    /// every field written matches what is stored, and the upsert lookup runs
    /// against a full store.
    ///
    /// Two iterations for the same runtime reason as the cold import; two is
    /// still enough to show whether the second pass is cheaper than the first.
    func testReimportFullXtreamCatalogUnchanged() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        insertLiveStreams(count: catalogLiveStreamCount, playlistId: playlistId, container: store.container)
        insertMovies(count: catalogMovieCount, playlistId: playlistId, container: store.container)
        insertSeries(count: catalogSeriesCount, playlistId: playlistId, container: store.container)

        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            insertLiveStreams(count: catalogLiveStreamCount, playlistId: playlistId, container: store.container)
            insertMovies(count: catalogMovieCount, playlistId: playlistId, container: store.container)
            insertSeries(count: catalogSeriesCount, playlistId: playlistId, container: store.container)
        }
    }

    // MARK: - Prune

    /// The mark-and-sweep prune over a full VOD catalog with **nothing to
    /// delete** — what every re-sync of a stable provider pays purely to
    /// establish that no row has gone away.
    ///
    /// This drives the production `ContentSyncManager.pruneStaleMovies` rather
    /// than a local copy of the sweep, so a paged rewrite of that method is
    /// genuinely gated by this number instead of drifting away from it.
    /// `ContentSyncManager` is an actor, so the measured block hands the call to
    /// a detached task and blocks on a semaphore: `Task.detached` specifically,
    /// because a task that inherited this test's context could not start while
    /// the semaphore holds that context's thread. The manager's default
    /// `XtreamClient` is never used — the sweep only touches the store.
    ///
    /// Memory is measured alongside the clock because the sweep's cost is
    /// materialising every row, not the deletes; a rewrite that only moves wall
    /// clock has not fixed it.
    func testPruneFullVODCatalogWithNoDeletions() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        insertMovies(count: catalogMovieCount, playlistId: playlistId, container: store.container)

        let manager = ContentSyncManager(modelContainer: store.container)
        // Every id is "seen", so no row is deleted and every iteration sweeps
        // the same 178k rows — without this the second pass would measure an
        // empty table.
        let seenIds = Set((0 ..< catalogMovieCount).map { "\(playlistId.uuidString)-movie-\($0)" })

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await manager.pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    // MARK: - Helpers

    /// Runs `work` against a freshly created on-disk store on every iteration, so
    /// each pass starts from an empty database and the numbers are comparable.
    /// Store setup/teardown sit outside the measured region.
    private func measureStoreWork(
        metrics: [XCTMetric],
        iterationCount: Int = 5,
        _ work: (ModelContainer) -> Void
    ) {
        // Manual start/stop is what keeps store creation and deletion — tens of
        // milliseconds of file I/O each — out of the numbers.
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

    /// The upsert loop `ContentSyncManager.syncMovies` runs: one fresh,
    /// autosave-off context per batch, an id-scoped fetch for existing rows,
    /// insert-or-update, and a save that only happens when something actually
    /// changed.
    ///
    /// This is a local copy of the loop, not a call into it — `syncMovies` is
    /// driven by a network fetch. It therefore has to be kept in step with
    /// `ContentSyncManager+Helpers.applyMovieFields` by hand: the per-field
    /// inequality guards and the `hasChanges` gate below mirror that helper, and
    /// are what makes the unchanged re-import benchmark measure the refresh path
    /// the app actually runs.
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
                    }
                    applyMovieFixture(index: index, playlistId: playlistId, to: movie)
                }
                if context.hasChanges { try? context.save() }
            }
        }
    }

    /// The series equivalent of `insertMovies`, matching `syncSeries`: same
    /// context-per-batch upsert, and the same `GenreParser.providerFallback`
    /// routing `applySeriesFields` uses — the provider genre is a fallback, so
    /// the dirty check compares the computed value, not the raw one.
    private func insertSeries(count: Int, playlistId: UUID, container: ModelContainer) {
        // ~1 KB of prose per row, which is what the measured provider sends and
        // what makes series the heaviest kind to write.
        let plotBody = String(repeating: "A long-running drama that follows its cast across several seasons. ", count: 12)
        let castBody = String(repeating: "Alex Doe, Sam Roe, Jamie Poe, Riley Coe, ", count: 6)

        for batchStart in stride(from: 0, to: count, by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, count)
                let context = ModelContext(container)
                context.autosaveEnabled = false

                let ids = (batchStart ..< batchEnd).map { "\(playlistId.uuidString)-series-\($0)" }
                var existing: [String: Series] = [:]
                existing.reserveCapacity(ids.count)
                let fetched = (try? context.fetch(
                    FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
                )) ?? []
                for series in fetched {
                    existing[series.id] = series
                }

                for index in batchStart ..< batchEnd {
                    let id = "\(playlistId.uuidString)-series-\(index)"
                    let series: Series
                    if let found = existing[id] {
                        series = found
                    } else {
                        series = Series(id: id, seriesId: index, name: "")
                        context.insert(series)
                    }
                    applySeriesFixture(index: index, playlistId: playlistId, plot: plotBody, cast: castBody, to: series)
                }
                if context.hasChanges { try? context.save() }
            }
        }
    }

    /// The live-channel equivalent of `insertMovies`, matching `syncLiveStreams`.
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
                    }
                    applyLiveStreamFixture(index: index, playlistId: playlistId, to: stream)
                }
                if context.hasChanges { try? context.save() }
            }
        }
    }

    // The three field appliers below stand in for
    // `ContentSyncManager+Helpers.apply*Fields`: one guarded assignment per
    // provider-owned property, so a re-import of an unchanged catalog leaves the
    // context clean and skips `save()` — the whole point of the refresh-path
    // benchmarks. The complexity opt-outs match the ones on those helpers: this
    // is a flat field copy, not branching logic.

    private func applyMovieFixture(index: Int, playlistId: UUID, to movie: Movie) {
        let name = "Movie \(index)"
        if movie.name != name { movie.name = name }
        let streamIcon = "https://example.invalid/p/\(index).jpg"
        if movie.streamIcon != streamIcon { movie.streamIcon = streamIcon }
        let rating = Double(index % 10)
        if movie.rating != rating { movie.rating = rating }
        let added = "\(1_700_000_000 + index)"
        if movie.added != added { movie.added = added }
        if movie.containerExtension != "mkv" { movie.containerExtension = "mkv" }
        let categoryId = "\(playlistId.uuidString)-vod-\(index % 300)"
        if movie.categoryId != categoryId { movie.categoryId = categoryId }
    }

    private func applySeriesFixture( // swiftlint:disable:this cyclomatic_complexity
        index: Int,
        playlistId: UUID,
        plot plotBody: String,
        cast castBody: String,
        to series: Series
    ) {
        let name = "Series \(index)"
        if series.name != name { series.name = name }
        let cover = "https://example.invalid/c/\(index).jpg"
        if series.cover != cover { series.cover = cover }
        let plot = "\(plotBody)Episode arc \(index)."
        if series.plot != plot { series.plot = plot }
        if series.cast != castBody { series.cast = castBody }
        let director = "Director \(index % 900)"
        if series.director != director { series.director = director }
        // The provider genre is a fallback, so the guard compares the computed
        // value — exactly as `applySeriesFields` must.
        let genre = GenreParser.providerFallback(current: series.genre, provider: "Drama, Thriller")
        if series.genre != genre { series.genre = genre }
        let releaseDate = "20\(10 + index % 15)-04-11"
        if series.releaseDate != releaseDate { series.releaseDate = releaseDate }
        let lastModified = "\(1_700_000_000 + index)"
        if series.lastModified != lastModified { series.lastModified = lastModified }
        let rating = "\(index % 10)"
        if series.rating != rating { series.rating = rating }
        let rating5Based = "\(index % 5)"
        if series.rating5Based != rating5Based { series.rating5Based = rating5Based }
        if series.num != index { series.num = index }
        let categoryId = "\(playlistId.uuidString)-series-\(index % 400)"
        if series.categoryId != categoryId { series.categoryId = categoryId }
    }

    private func applyLiveStreamFixture(index: Int, playlistId: UUID, to stream: LiveStream) {
        let name = "Channel \(index) HD"
        if stream.name != name { stream.name = name }
        let streamIcon = "https://example.invalid/logo/\(index).png"
        if stream.streamIcon != streamIcon { stream.streamIcon = streamIcon }
        // The provider leaves roughly a third of these empty.
        let epgChannelId = index % 3 == 0 ? "" : "channel.\(index).xx"
        if stream.epgChannelId != epgChannelId { stream.epgChannelId = epgChannelId }
        let added = "\(1_700_000_000 + index)"
        if stream.added != added { stream.added = added }
        let tvArchive = index % 4 == 0 ? 1 : 0
        if stream.tvArchive != tvArchive { stream.tvArchive = tvArchive }
        let tvArchiveDuration = index % 4 == 0 ? 7 : 0
        if stream.tvArchiveDuration != tvArchiveDuration { stream.tvArchiveDuration = tvArchiveDuration }
        if stream.num != index { stream.num = index }
        let categoryId = "\(playlistId.uuidString)-live-\(index % 900)"
        if stream.categoryId != categoryId { stream.categoryId = categoryId }
    }
}
