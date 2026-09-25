//
//  M3UColdImportBenchmarks.swift
//  LumePerformanceTests
//
//  The first benchmark that drives the *production* m3u cold import end to end.
//
//  `M3UPersistenceBenchmarks` measures the store side through hand-written
//  copies of `importLive`/`importMovies`/`importEpisodes`, so it never touches
//  parse, classification, `ensureCategories`, `seedInsertOrder` or the five
//  post-import sweeps — which is most of the wall clock a user waits on. This
//  suite drives `ContentSyncManager.syncPlaylist` against a `file://` playlist,
//  which is the same entry point the file importer uses, so every phase in the
//  pipeline is inside the number.
//
//  Clock and memory are measured in the same pass as every m3u signpost: peak
//  RSS is the Apple TV jetsam contract (no swap — a jetsammed sync reads as
//  "the sync never finishes"), and a second pass per phase would mean a second
//  full import per phase.
//
//  This suite cannot build for tvOS — `appletvos` is not in
//  `LumePerformanceTests`' `SUPPORTED_PLATFORMS` — so every Apple TV statement
//  here is an inference from the iPhone-simulator proxy. Confirming one on the
//  device it is about needs the manual `xctrace` recipe in
//  `LumePerformanceTests/README.md`, "Tracing a real Apple TV".
//

// MARK: - Measured baseline

//  2026-09-08 — iPhone 17 Pro simulator (iOS 26.4), Benchmark configuration,
//  600,000 entries / 15,000 shows, which the import resolves to 18,000 live,
//  66,000 movies and 516,000 episodes.
//
//    Clock Monotonic Time      191.9 s
//    Memory Peak Physical      154,930 kB
//    Memory Physical (growth)      934 kB
//
//    M3UImport                 194.9 s   parse + classify + upsert + all five sweeps
//      M3UPruneEpisodes         58.301 s
//      M3UPruneMovies            4.456 s
//      M3UPruneSeries            0.730 s
//      M3UPruneLive              0.542 s
//      M3UPruneCategories        0.038 s
//    CatalogPurgeHistory         0.856 s
//      → sweeps + purge         64.9 s   (33% of the import)
//      → batch loop            130.0 s   (67%)
//
//  Measured while the purge still ran inside `importM3UFile`, so it is inside
//  the `M3UImport` figure above. It has since moved to `performSync`, where
//  every source path reclaims — a re-measure reports `M3UImport` ~0.9 s lower
//  and `CatalogPurgeHistory` beside it rather than nested.
//
//  The five sweeps, the purge and `M3UImport` are one interval each, so those
//  figures are exact. The per-batch phases are not: `XCTOSSignpostMetric`
//  reports a single value per name per iteration, and with ~301 intervals
//  sharing a name it keeps the *first* interval, not their sum. This fixture
//  emits every live entry before any VOD, so batch 1 is all-live:
//
//    M3UParse         0.019 s   first inter-batch gap
//    M3UClassify      0.021 s   first batch, 2,000 live entries
//    M3UUpsertLive    0.036 s   first batch, 2,000 live rows
//    M3UUpsertMovies  ~0 s      no movies in batch 1
//    M3UUpsertEpisodes 0 s      no episodes in batch 1
//
//  A pass is ~3 minutes and `measure` runs the block twice (the first pass is
//  not reported).
//
//  Two identical builds spread +1.9% on the clock and −8.7% on peak RSS here;
//  read any comparison at that resolution.
//
//  How this branch got from 571.5 s / 1,120,276 kB to the numbers above — every
//  delta, which lever moved which one, and what is left on the table — is in
//  `LumePerformanceTests/README.md`, "The m3u cold path, measured end to end".
//  Record a new run there rather than appending a second ledger here.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class M3UColdImportBenchmarks: XCTestCase {
    /// The real provider file this work is aimed at carries 1,729,847 entries.
    /// The suite runs at 600,000 so one iteration finishes in a normal sitting;
    /// raise this constant (and nothing else) to measure closer to full scale.
    private static let entryCount = 600_000

    /// `writeM3UProviderShape`'s long-tailed draw averages ~37 episodes per
    /// show, so ~`entryCount / 43` shows are consumed exactly once. Surplus
    /// shows are simply never emitted rather than shortening the blocks, so
    /// `/ 40` is the safe side of that.
    private static let showCount = entryCount / 40

    private var scratch: URL!
    private var fixtureURL: URL!

    /// The fixture is ~180 MB at 600k entries and takes real time to write, so
    /// it is generated once here rather than inside the measured block.
    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try PerfFixtures.makeScratchDirectory()
        fixtureURL = try PerfFixtures.writeM3UProviderShape(
            entryCount: Self.entryCount, showCount: Self.showCount, to: scratch
        )
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        fixtureURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Cold import

    /// A first import of a provider-shaped playlist into an empty store:
    /// download stub, streaming parse, classification, category creation,
    /// insert-order seeding, the three upsert loops and all five sweeps.
    ///
    /// One iteration: a pass writes ~600k rows through a real SQLite file. The
    /// comparison that matters is between commits, not between passes of one
    /// run.
    func testColdImportProviderShapedPlaylist() throws {
        let fixtureURL = try XCTUnwrap(fixtureURL)

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 1
        measure(metrics: Self.coldImportMetrics, options: options) {
            guard let store = try? PerfStore.makeOnDiskContainer() else {
                XCTFail("could not create the on-disk store")
                return
            }
            defer { PerfStore.destroy(directory: store.directory) }

            guard let playlistId = try? seedM3UPlaylist(fileURL: fixtureURL, container: store.container) else {
                XCTFail("could not seed the playlist row")
                return
            }
            clearM3UDeviceLocalState(playlistId: playlistId)
            defer { clearM3UDeviceLocalState(playlistId: playlistId) }

            let manager = ContentSyncManager(modelContainer: store.container)
            startMeasuring()
            let outcome = syncPlaylistSynchronously(
                manager: manager, playlistId: playlistId, container: store.container
            )
            stopMeasuring()

            if let error = outcome.error {
                XCTFail("m3u sync failed: \(error)")
            }
            assertCatalogWasWritten(container: store.container)
        }
    }

    // MARK: - Metrics

    /// Clock, memory and every m3u phase in one `metrics:` array. Split into
    /// one test per signpost, each test would re-run a full 600k import.
    private static var coldImportMetrics: [XCTMetric] {
        var metrics: [XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()]
        metrics.append(contentsOf: m3uSignposts.map(signpostMetric))
        return metrics
    }

    /// `.m3uParse` is emitted once per *gap between batches* — ~860 intervals
    /// for a full provider file — and `.m3uClassify` / the three `.m3uUpsert*`
    /// once per batch. `XCTOSSignpostMetric` keeps one value per name per
    /// iteration and that value is the first of those intervals, not their sum,
    /// so read those five as a first-batch sample; see the baseline block above.
    /// The five sweeps, `.catalogPurgeHistory` and `.m3uImport` are one
    /// interval each and are exact. `.catalogPurgeHistory` is emitted by
    /// `performSync` for every source, so it sits beside `.m3uImport` rather
    /// than inside it.
    static let m3uSignposts: [PerfSignpost] = [
        .m3uImport,
        .m3uParse,
        .m3uClassify,
        .m3uUpsertLive,
        .m3uUpsertMovies,
        .m3uUpsertEpisodes,
        .m3uPruneLive,
        .m3uPruneMovies,
        .m3uPruneEpisodes,
        .m3uPruneSeries,
        .m3uPruneCategories,
        .catalogPurgeHistory
    ]

    static func signpostMetric(_ signpost: PerfSignpost) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: Perf.subsystem, category: Perf.category, name: signpost.metricName)
    }

    // MARK: - Harness

    /// A silently empty import would measure a no-op and report it as a win.
    private func assertCatalogWasWritten(container: ModelContainer) {
        let context = ModelContext(container)
        let live = (try? context.fetchCount(FetchDescriptor<LiveStream>())) ?? 0
        let movies = (try? context.fetchCount(FetchDescriptor<Movie>())) ?? 0
        let episodes = (try? context.fetchCount(FetchDescriptor<Episode>())) ?? 0
        XCTAssertGreaterThan(live, 0, "no live channels imported")
        XCTAssertGreaterThan(movies, 0, "no movies imported")
        XCTAssertGreaterThan(episodes, 0, "no episodes imported")
    }
}
