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

    // MARK: - Helpers

    /// Runs `work` against a freshly created on-disk store on every iteration, so
    /// each pass starts from an empty database and the numbers are comparable.
    /// Store setup/teardown sit outside the measured region.
    private func measureStoreWork(
        metrics: [XCTMetric],
        _ work: (ModelContainer) -> Void
    ) {
        // Manual start/stop is what keeps store creation and deletion — tens of
        // milliseconds of file I/O each — out of the numbers.
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
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
    /// autosave-off context per batch, an id-scoped fetch for existing rows, then
    /// insert-or-update and save.
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
                    movie.name = "Movie \(index)"
                    movie.streamIcon = "https://example.invalid/p/\(index).jpg"
                    movie.rating = Double(index % 10)
                    movie.added = "\(1_700_000_000 + index)"
                    movie.containerExtension = "mkv"
                    movie.categoryId = "\(playlistId.uuidString)-vod-\(index % 300)"
                }
                try? context.save()
            }
        }
    }
}
