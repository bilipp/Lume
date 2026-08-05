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
        seedGuide()
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

    // MARK: - Instrumentation integrity

    /// Two milestones sharing a name would silently merge into one metric, so a
    /// benchmark would measure the wrong thing without ever failing. Cheap guard.
    func testSignpostNamesAreUnique() {
        let all: [PerfSignpost] = [
            .playlistSync, .syncCategories, .syncMovies, .syncSeries, .syncLiveStreams,
            .m3uDownload, .m3uImport,
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
