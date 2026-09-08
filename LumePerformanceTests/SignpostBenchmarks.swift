//
//  SignpostBenchmarks.swift
//  LumePerformanceTests
//
//  Tier B: measure the app's own named phases rather than a benchmark's
//  reimplementation of them.
//
//  `XCTOSSignpostMetric` reads the `OSSignposter` intervals the app emits (see
//  `PerformanceSignposts.swift`), so these tests time *production* code paths by
//  name. They double as a tripwire on the instrumentation itself: rename or drop
//  a signpost and the matching test fails with "no samples" instead of quietly
//  measuring nothing.
//
//  Treat these as coarse (2× regression) checks, not 5% gates — they include
//  whatever the phase legitimately does.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class SignpostBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!
    private let channelCount = 200
    private let slotsPerChannel = 48
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PerfStore.makeOnDiskContainer()
    }

    override func tearDownWithError() throws {
        if let store {
            PerfStore.destroy(directory: store.directory)
        }
        store = nil
        try super.tearDownWithError()
    }

    /// Times the `ChannelEPGLoad` interval emitted from inside
    /// `ChannelEPGLoader.load` — production instrumentation, measured by name.
    func testChannelEPGLoadSignpost() {
        seedGuide()
        let channelIds = (0 ..< channelCount).map { "ch\($0)" }
        let now = epoch.addingTimeInterval(Double(slotsPerChannel) * 1800 / 2)
        let metric = XCTOSSignpostMetric(
            subsystem: Perf.subsystem,
            category: Perf.category,
            name: PerfSignpost.channelEPGLoad.metricName
        )

        measure(metrics: [metric]) {
            _ = ChannelEPGLoader.load(
                container: store.container, channelIds: channelIds, now: now
            )
        }
    }

    /// Same for the guide grid's window fetch.
    func testGuideWindowLoadSignpost() {
        seedGuide()
        let channelIds = (0 ..< channelCount).map { "ch\($0)" }
        let windowEnd = epoch.addingTimeInterval(Double(slotsPerChannel) * 1800)
        let metric = XCTOSSignpostMetric(
            subsystem: Perf.subsystem,
            category: Perf.category,
            name: PerfSignpost.guideWindowLoad.metricName
        )

        measure(metrics: [metric]) {
            _ = EPGGuideLoader.load(
                container: store.container,
                channelIds: channelIds,
                windowStart: epoch,
                windowEnd: windowEnd
            )
        }
    }

    /// The m3u import's phase signposts plus the shared post-sync history
    /// purge, driven by a real `syncPlaylist` over a deliberately tiny
    /// provider-shaped playlist.
    ///
    /// A tripwire, not a throughput number: `M3UColdImportBenchmarks` owns the
    /// timing at provider scale, and re-running a 600k import per phase would
    /// cost hours. What this catches is a renamed or dropped signpost, which
    /// otherwise turns that suite's per-phase split into silence rather than a
    /// failure — `XCTOSSignpostMetric` fails with "no samples" when its name
    /// stops being emitted.
    func testM3UImportSignposts() throws {
        let scratch = try PerfFixtures.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixtureURL = try PerfFixtures.writeM3UProviderShape(
            entryCount: 400, showCount: 10, to: scratch
        )

        let metrics = M3UColdImportBenchmarks.m3uSignposts.map(M3UColdImportBenchmarks.signpostMetric)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: metrics, options: options) {
            // A fresh store per iteration, as `M3UColdImportBenchmarks` does:
            // importing into a store that still holds the previous passes'
            // catalog would make each iteration warmer than the last.
            guard let iterationStore = try? PerfStore.makeOnDiskContainer() else {
                XCTFail("could not create the on-disk store")
                return
            }
            defer { PerfStore.destroy(directory: iterationStore.directory) }
            // The device-local skip state is cleared with the playlist: a
            // stored digest makes `m3uImportIsRedundant` short-circuit the
            // import, and the second pass would emit nothing.
            guard let playlistId = try? seedM3UPlaylist(
                fileURL: fixtureURL, container: iterationStore.container
            ) else {
                XCTFail("could not seed the playlist row")
                return
            }
            defer { clearM3UDeviceLocalState(playlistId: playlistId) }
            let outcome = syncPlaylistSynchronously(
                manager: ContentSyncManager(modelContainer: iterationStore.container),
                playlistId: playlistId,
                container: iterationStore.container,
                timeout: 120
            )
            if let error = outcome.error {
                XCTFail("m3u sync failed: \(error)")
            }
        }
    }

    // MARK: - Instrumentation integrity

    /// Two milestones sharing a name would silently merge into one metric, so a
    /// benchmark would measure the wrong thing without ever failing. Cheap guard.
    func testSignpostNamesAreUnique() {
        let all: [PerfSignpost] = [
            .playlistSync, .syncCategories, .syncMovies, .syncSeries, .syncLiveStreams,
            .xtreamFetchMovies, .xtreamDecodeMovies, .upsertMovies, .pruneMovies,
            .xtreamFetchSeries, .xtreamDecodeSeries, .upsertSeries, .pruneSeries,
            .xtreamFetchLiveStreams, .xtreamDecodeLiveStreams, .upsertLiveStreams, .pruneLiveStreams,
            .xtreamPhaseSpacing,
            .m3uDownload, .m3uImport,
            .m3uParse, .m3uClassify,
            .m3uUpsertLive, .m3uUpsertMovies, .m3uUpsertEpisodes,
            .m3uPruneLive, .m3uPruneMovies, .m3uPruneEpisodes, .m3uPruneSeries, .m3uPruneCategories,
            .catalogPurgeHistory,
            .epgSourceSync, .epgIngest, .channelEPGLoad, .guideWindowLoad,
            .homeTrendingLoad, .homeRecommendations,
            .playerStartup, .playerRebuffer, .playerEngineFallback, .playerStartupFailure
        ]
        let names = all.map(\.metricName)
        XCTAssertEqual(
            Set(names).count, names.count,
            "duplicate signpost name: \(names.sorted())"
        )
        for name in names {
            XCTAssertFalse(name.isEmpty, "a signpost has an empty name")
        }
    }

    /// The subsystem must match `Logger`'s, so one Instruments filter covers both
    /// signposts and log messages. Both derive from the bundle id.
    func testSignpostSubsystemMatchesBundle() {
        XCTAssertEqual(Perf.subsystem, Bundle.main.bundleIdentifier)
    }

    // MARK: - Seeding

    private func seedGuide() {
        let context = ModelContext(store.container)
        context.autosaveEnabled = false
        for channel in 0 ..< channelCount {
            autoreleasepool {
                for slot in 0 ..< slotsPerChannel {
                    let start = epoch.addingTimeInterval(Double(slot) * 1800)
                    context.insert(EPGListing(
                        id: "ch\(channel)-\(Int(start.timeIntervalSince1970))",
                        channelId: "ch\(channel)",
                        title: "Programme \(channel)-\(slot)",
                        listingDescription: "Synthetic description.",
                        start: start,
                        end: start.addingTimeInterval(1800)
                    ))
                }
            }
        }
        try? context.save()
    }
}
