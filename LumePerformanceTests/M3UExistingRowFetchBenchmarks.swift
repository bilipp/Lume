//
//  M3UExistingRowFetchBenchmarks.swift
//  LumePerformanceTests
//
//  How the two per-batch IN-clause lookups in `importEpisodes` —
//  `existingSeries(ids:)` and `existingEpisodes(ids:)`, each with up to 2,000
//  ids — behave as their tables grow to provider scale.
//
//  `LumePerformanceTests/README.md` lists the per-batch existing-row lookup as
//  one of four "under 6%" dead levers. That figure came from a standalone
//  178k-row harness that is no longer in the repo, and index probes get more
//  expensive as the B-tree deepens, so it does not transfer to a 1.5M-row
//  `Episode` table on its own evidence. This measures it at 150k, 500k and
//  1.5M rows in one pass.
//
//  Not an `XCTClockMetric` suite: one fetch is milliseconds, `measure` may only
//  be called once per test method, and three separate methods would mean three
//  separate seedings of a 1.5M-row store. One test that seeds *through* the
//  three sizes and times a batch of fetches at each is both cheaper and more
//  precise. Results are printed; `Scripts/run-performance-tests.sh` keeps the
//  full log.
//
//  Measured 2026-09-08, iPhone 17 Pro simulator (iOS 26.4), one fetch of 2,000
//  ids, mean of 20. Contiguous episode ids — the production shape — are flat at
//  43.41 / 42.46 / 42.29 ms across 150k / 500k / 1.5M rows; only the spread
//  control grows (51.39 / 60.13 / 70.18 ms), so the cost is page locality, not
//  tree depth. The deduped series lookup stays at 3.6-3.8 ms. The README's
//  "under 6%" for this lookup holds at provider scale.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class M3UExistingRowFetchBenchmarks: XCTestCase {
    /// Table sizes to sample, seeded cumulatively. The last is the measured
    /// provider's ~1,485,000 episodes.
    private static let stages = [150_000, 500_000, 1_500_000]

    /// ~1,485,000 episodes across ~43,500 shows.
    private static let episodesPerSeries = 34

    /// `ContentSyncManager.batchSize` — the largest IN-clause the import builds.
    private static let idsPerFetch = 2000

    /// Enough repetitions that a single page-cache miss cannot own the mean.
    private static let repetitions = 20

    private static let seedBatchSize = 2000

    // MARK: - Scaling

    func testExistingRowFetchCostScalesWithTableSize() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let playlistId = UUID()
        // The shipped lookups, called rather than copied. Built once and
        // outside every timed block — its `XtreamClient` opens a `URLSession`.
        let lookups = ContentSyncManager(modelContainer: store.container)

        var seeded = 0
        var lines: [String] = []
        for stage in Self.stages {
            seed(from: seeded, upTo: stage, playlistId: playlistId, container: store.container)
            seeded = stage

            // A real batch is 2,000 *consecutive* file entries, so its ids land
            // in one region of the index. The spread window is the control: if
            // the two diverge, the cost is page locality rather than tree depth.
            let contiguous = episodeIds(from: stage / 2, count: Self.idsPerFetch, playlistId: playlistId)
            let spread = episodeIds(
                stride: max((stage - 1) / Self.idsPerFetch, 1), count: Self.idsPerFetch, playlistId: playlistId
            )
            let series = seriesIds(forEpisodesFrom: stage / 2, count: Self.idsPerFetch, playlistId: playlistId)

            let contiguousMs = timeFetch(expected: contiguous.count, container: store.container) {
                lookups.existingEpisodes(ids: contiguous, context: $0).count
            }
            let spreadMs = timeFetch(expected: spread.count, container: store.container) {
                lookups.existingEpisodes(ids: spread, context: $0).count
            }
            // `existingSeries` deduplicates the ids before it fetches — 2,000
            // episode rows name only ~59 shows, so the IN-clause it builds is
            // two orders of magnitude smaller than the episode one.
            let seriesMs = timeFetch(expected: Set(series).count, container: store.container) {
                lookups.existingSeries(ids: series, context: $0).count
            }

            lines.append(
                String(
                    format: "PERF-INCLAUSE rows=%d episodes-contiguous=%.2fms episodes-spread=%.2fms series=%.2fms",
                    stage, contiguousMs, spreadMs, seriesMs
                )
            )
        }
        for line in lines {
            print(line)
        }
        XCTAssertEqual(lines.count, Self.stages.count)
    }

    // MARK: - Timing

    /// A fresh `ModelContext` per repetition, as the import uses one per batch:
    /// reusing a context would serve later fetches from its row cache and
    /// measure a lookup the import never performs.
    private func timeFetch(
        expected: Int,
        container: ModelContainer,
        fetch: (ModelContext) -> Int
    ) -> Double {
        var total: Duration = .zero
        for _ in 0 ..< Self.repetitions {
            autoreleasepool {
                let context = ModelContext(container)
                let clock = ContinuousClock()
                let start = clock.now
                let count = fetch(context)
                total += clock.now - start
                XCTAssertEqual(count, expected, "sample ids must all exist")
            }
        }
        return total.milliseconds / Double(Self.repetitions)
    }

    // MARK: - Seeding

    /// Deliberately *not* the production upsert: no existence fetch, no dirty
    /// check, no relationship. This suite measures the lookup, not the write,
    /// and skipping the rest is what keeps seeding 1.5M rows to minutes. The
    /// resulting table — row count, id shape, unique index — is what the lookup
    /// actually probes.
    private func seed(from: Int, upTo: Int, playlistId: UUID, container: ModelContainer) {
        for batchStart in stride(from: from, to: upTo, by: Self.seedBatchSize) {
            autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                for index in batchStart ..< min(batchStart + Self.seedBatchSize, upTo) {
                    if index % Self.episodesPerSeries == 0 {
                        let showIndex = index / Self.episodesPerSeries
                        context.insert(
                            Series(
                                id: seriesId(showIndex: showIndex, playlistId: playlistId),
                                seriesId: showIndex,
                                name: "Show \(showIndex)"
                            )
                        )
                    }
                    context.insert(
                        Episode(
                            id: episodeId(index: index, playlistId: playlistId),
                            episodeId: "\(index)",
                            title: "Episode \(index)",
                            containerExtension: "mkv",
                            seasonNum: index % 30 + 1,
                            episodeNum: index % 30 + 1
                        )
                    )
                }
                try? context.save()
            }
        }
    }

    // MARK: - Ids

    // The id shapes `importEpisodes` builds: a base-36 FNV-1a hash under the
    // playlist's UUID, with the episode id carrying its series id as a prefix.
    // Length matters here — it is what the index compares.

    private func seriesId(showIndex: Int, playlistId: UUID) -> String {
        M3UIdentity.seriesId(playlistId: playlistId, name: "Show \(showIndex)")
    }

    private func episodeId(index: Int, playlistId: UUID) -> String {
        let url = "https://example.invalid/series/92mc7c964u/n835i3j9a6/\(200_000 + index).mkv"
        return M3UIdentity.episodeId(
            seriesId: seriesId(showIndex: index / Self.episodesPerSeries, playlistId: playlistId),
            url: url
        )
    }

    private func episodeIds(from start: Int, count: Int, playlistId: UUID) -> [String] {
        (start ..< start + count).map { episodeId(index: $0, playlistId: playlistId) }
    }

    private func episodeIds(stride step: Int, count: Int, playlistId: UUID) -> [String] {
        (0 ..< count).map { episodeId(index: $0 * step, playlistId: playlistId) }
    }

    private func seriesIds(forEpisodesFrom start: Int, count: Int, playlistId: UUID) -> [String] {
        (start ..< start + count).map {
            seriesId(showIndex: $0 / Self.episodesPerSeries, playlistId: playlistId)
        }
    }
}
