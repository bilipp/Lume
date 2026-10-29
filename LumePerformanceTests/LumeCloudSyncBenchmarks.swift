//
//  LumeCloudSyncBenchmarks.swift
//  LumePerformanceTests
//
//  The Lume Cloud push at the size a heavy library reaches: 100,000
//  `UserContentState` rows across three profiles in an on-disk Lume Cloud store.
//  Every reconcile pass ends in a push. The first one reads every mirror row,
//  encodes its canonical payload and compares it with the last synced bytes;
//  later ones diff only the rows persistent history shows another context
//  changed — so the unchanged pass is the cost a user pays on every sync, the
//  100-row pass the cost of an ordinary one, and the first push (seal, batch,
//  bookkeeping) is what joining with a large library costs.
//  `PerfLumeCloudFeed` stands in for the server.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SQLite3
import SwiftData
import XCTest

final class LumeCloudSyncBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!

    private let contentRows = 100_000
    private let changedRows = 100
    private let accountId = "acct-perf"
    private let rootKey = Data((0 ..< 32).map { UInt8($0) })
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private let profileIDs = (1 ... 3).map { index in
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private var expectedBatches: Int {
        (contentRows + LumeCloudAPI.maxPushRecords - 1) / LumeCloudAPI.maxPushRecords
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskLumeCloudContainer()
        try seedContentStates()
    }

    override func tearDownWithError() throws {
        if let store {
            PerfStore.destroy(directory: store.directory)
        }
        store = nil
        try super.tearDownWithError()
    }

    /// A first push of every row: diff against empty bookkeeping, seal, split
    /// into 500-record requests, and store each success as the merge base. Each
    /// iteration starts from cleared bookkeeping, outside the measured span.
    func testFirstPushOf100kContentRows() {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: pushMetrics, options: options) {
            do {
                try clearBookkeeping()
                try truncateWAL()
            } catch {
                XCTFail("preparing the iteration failed: \(error)")
            }
            let feed = PerfLumeCloudFeed()
            startMeasuring()
            let outcome = push(into: feed)
            stopMeasuring()
            XCTAssertEqual(outcome?.result.pushedRecords, contentRows)
            XCTAssertEqual(feed.pushRequestCount, expectedBatches)
        }
    }

    /// The same rows pushed again with nothing changed, after a first push
    /// stored a history token: the per-pass cost every reconcile pays. Reads
    /// history, diffs nothing, sends nothing and writes nothing.
    func testUnchangedPushOf100kContentRows() throws {
        let feed = PerfLumeCloudFeed()
        XCTAssertEqual(push(into: feed)?.result.pushedRecords, contentRows)
        XCTAssertNotNil(try storedHistoryToken(), "the first push must leave a history token")
        let requestsAfterFirstPush = feed.pushRequestCount

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: pushMetrics, options: options) {
            do {
                try truncateWAL()
            } catch {
                XCTFail("truncating the WAL failed: \(error)")
            }
            startMeasuring()
            let outcome = push(into: feed)
            stopMeasuring()
            XCTAssertEqual(outcome?.result.pushedRecords, 0)
            XCTAssertEqual(outcome?.encodedRows, 0)
        }
        XCTAssertEqual(feed.pushRequestCount, requestsAfterFirstPush)
    }

    /// 100 of the 100,000 rows changed by another context since the last push,
    /// as the engine's reconcile writes them: the history path diffs, seals and
    /// sends those 100 and nothing else.
    func testPushOf100ChangedOf100kContentRows() throws {
        let feed = PerfLumeCloudFeed()
        XCTAssertEqual(push(into: feed)?.result.pushedRecords, contentRows)
        XCTAssertNotNil(try storedHistoryToken(), "the first push must leave a history token")

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var iteration = 0
        measure(metrics: pushMetrics, options: options) {
            do {
                try editContentRows(changedRows, iteration: iteration)
                try truncateWAL()
            } catch {
                XCTFail("preparing the iteration failed: \(error)")
            }
            iteration += 1
            let requestsBefore = feed.pushRequestCount
            startMeasuring()
            let outcome = push(into: feed)
            stopMeasuring()
            XCTAssertEqual(outcome?.result.pushedRecords, changedRows)
            XCTAssertEqual(outcome?.encodedRows, changedRows)
            XCTAssertEqual(feed.pushRequestCount, requestsBefore + 1)
        }
    }

    // MARK: - Harness

    /// Clock, peak RSS, the push signpost and the bytes the push left in the
    /// store's write-ahead log.
    private var pushMetrics: [XCTMetric] {
        [
            XCTClockMetric(),
            XCTMemoryMetric(),
            M3UColdImportBenchmarks.signpostMetric(.lumeCloudPush),
            PerfWALGrowthMetric(storeURL: PerfStore.lumeCloudStoreURL(in: store.directory))
        ]
    }

    /// One push on a detached task, as the coordinator runs it: the transport
    /// is an actor with its own `ModelContext`, never the main one. Also
    /// returns how many mirror rows the push encoded to diff them.
    private func push(into feed: PerfLumeCloudFeed) -> (result: LumeCloudPushResult, encodedRows: Int)? {
        let container = store.container
        let rootKey = rootKey
        let accountId = accountId
        let finished = expectation(description: "lume cloud push")
        nonisolated(unsafe) var outcome: (result: LumeCloudPushResult, encodedRows: Int)?
        Task.detached {
            do {
                let transport = try LumeCloudTransport(client: feed, container: container, rootKey: rootKey, accountId: accountId)
                let result = try await transport.push()
                outcome = await (result, transport.upsertEncodeCount)
            } catch {
                XCTFail("Lume Cloud push failed: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 600)
        return outcome
    }

    private func storedHistoryToken() throws -> Data? {
        try ModelContext(store.container).fetch(FetchDescriptor<LumeCloudSyncMeta>()).first?.historyToken
    }

    /// Changes `count` rows in a context that isn't the transport's, so
    /// persistent history records them under another author. Each iteration
    /// takes the next `count` rows and moves their progress on.
    private func editContentRows(_ count: Int, iteration: Int) throws {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<UserContentState>()
        descriptor.fetchOffset = iteration * count
        descriptor.fetchLimit = count
        let rows = try context.fetch(descriptor)
        XCTAssertEqual(rows.count, count)
        let editedAt = epoch.addingTimeInterval(Double(iteration + 1))
        for row in rows {
            row.watchProgress += 1
            row.updatedAt = editedAt
        }
        try context.save()
    }

    /// Checkpoints the store's write-ahead log into the database and truncates
    /// it to zero, so the next measured span's WAL size is what that span wrote.
    private func truncateWAL() throws {
        let path = PerfStore.lumeCloudStoreURL(in: store.directory).path
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw PerfWALError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        sqlite3_busy_timeout(database, 10000)
        guard sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
            throw PerfWALError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func clearBookkeeping() throws {
        let context = ModelContext(store.container)
        try context.delete(model: LumeCloudRecordState.self)
        try context.delete(model: LumeCloudSyncMeta.self)
        try context.save()
    }

    // MARK: - Seeding

    /// The mix of a long-used library: mostly episode and movie progress, a
    /// smaller share of channel and series favourites, a few categories.
    private func seedContentStates() throws {
        var generator = SeededGenerator()
        let kinds: [SyncedContentKind] = [
            .episode, .episode, .episode, .episode, .episode, .episode, .episode, .episode, .episode, .episode,
            .movie, .movie, .movie, .movie, .movie,
            .live, .live, .live,
            .series,
            .category
        ]
        let playlistPrefix = "8F0C1D2E-3A4B-4C5D-8E6F-708192A3B4C5"
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        for index in 0 ..< contentRows {
            autoreleasepool {
                let kind = PerfFixtures.pick(kinds, using: &generator)
                let hasProgress = kind == .movie || kind == .episode
                let isFavorite = generator.next() % 6 == 0
                let watchedAt = epoch.addingTimeInterval(-Double(generator.next() % 31_536_000))
                context.insert(UserContentState(
                    contentId: "\(playlistPrefix)-\(kind.rawValue)-\(index)",
                    kind: kind,
                    profileID: profileIDs[index % profileIDs.count],
                    watchProgress: hasProgress ? Double(generator.next() % 7200) : 0,
                    isWatched: hasProgress && generator.next() % 4 == 0,
                    lastWatchedDate: hasProgress ? watchedAt : nil,
                    isFavorite: isFavorite,
                    favoriteOrder: kind == .live && isFavorite ? index : nil,
                    isHidden: kind == .category && generator.next() % 10 == 0,
                    customOrder: kind == .category ? index : nil,
                    updatedAt: watchedAt
                ))
            }
            if index % 10000 == 9999 {
                try context.save()
            }
        }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserContentState>()), contentRows)
    }
}

extension PerfStore {
    /// A fresh on-disk Lume Cloud store (`LumeApp.makeLumeCloudContainer`'s
    /// schema: the mirror models plus the transport's bookkeeping) in a unique
    /// temp directory, never the app's own store file.
    static func makeOnDiskLumeCloudContainer() throws -> (container: ModelContainer, directory: URL) {
        try makeOnDiskContainer(
            schema: Schema(LumeApp.cloudMirrorModels + LumeApp.lumeCloudBookkeepingModels),
            configurationName: ContentSyncManager.lumeCloudMirrorConfigurationName,
            fileName: lumeCloudStoreFileName
        )
    }

    private static let lumeCloudStoreFileName = "perf-lumecloud.store"

    static func lumeCloudStoreURL(in directory: URL) -> URL {
        directory.appendingPathComponent(lumeCloudStoreFileName)
    }
}

private enum PerfWALError: Error {
    case sqlite(String)
}

/// The size of a store's `-wal` file at the end of the measured span minus its
/// size at the start. SQLite reuses the log from the top after each
/// checkpoint, so with the log truncated before the span this is the most it
/// held at once: 0 for a pass that wrote nothing.
final nonisolated class PerfWALGrowthMetric: NSObject, XCTMetric {
    private let storeURL: URL
    private var sizeAtStart = 0
    private var sizeAtEnd = 0

    init(storeURL: URL) {
        self.storeURL = storeURL
    }

    func copy(with _: NSZone? = nil) -> Any {
        PerfWALGrowthMetric(storeURL: storeURL)
    }

    func willBeginMeasuring() {
        sizeAtStart = walSize()
    }

    func didStopMeasuring() {
        sizeAtEnd = walSize()
    }

    func reportMeasurements(
        from _: XCTPerformanceMeasurementTimestamp,
        to _: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        [XCTPerformanceMeasurement(
            identifier: "org.getlume.perf.walGrowth",
            displayName: "WAL Growth",
            doubleValue: Double(sizeAtEnd - sizeAtStart) / 1024,
            unitSymbol: "kB",
            polarity: .prefersSmaller
        )]
    }

    private func walSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: storeURL.path + "-wal")[.size] as? Int) ?? 0
    }
}
