//
//  EPGQueryBenchmarks.swift
//  LumePerformanceTests
//
//  The two off-main EPG fetches that back every channel list and the guide grid.
//  Both exist because the view-context `@Query` versions of them froze the app:
//  hundreds of per-cell observers each scanning the guide table, all re-firing on
//  every sync write. The fetches are now scoped, indexed and off-main — and these
//  benchmarks are what keep them that way.
//
//  Each test seeds a realistic guide once (outside the measured region) and then
//  measures only the fetch, since seeding costs far more than the query.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class EPGQueryBenchmarks: XCTestCase {
    private var store: (container: ModelContainer, directory: URL)!

    /// 400 channels × 96 half-hour slots ≈ two days of guide for a mid-size
    /// playlist.
    private let channelCount = 400
    private let slotsPerChannel = 96
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

    /// Now/next for every channel in a large category — the fetch a channel list
    /// runs once per load.
    func testChannelEPGLoadFor400Channels() {
        let channelIds = (0 ..< channelCount).map { "ch\($0)" }
        // Mid-guide, so the `end > now` bound has to discard roughly half the rows.
        let now = epoch.addingTimeInterval(Double(slotsPerChannel) * 1800 / 2)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = ChannelEPGLoader.load(
                container: store.container, channelIds: channelIds, now: now
            )
            XCTAssertEqual(result.count, channelCount)
        }
    }

    /// Now/next for one screenful of channels — the common case, and the one that
    /// must stay fast enough to run on every scroll-driven reload.
    func testChannelEPGLoadForVisibleWindow() {
        let channelIds = (0 ..< 30).map { "ch\($0)" }
        let now = epoch.addingTimeInterval(Double(slotsPerChannel) * 1800 / 2)

        measure(metrics: [XCTClockMetric()]) {
            let result = ChannelEPGLoader.load(
                container: store.container, channelIds: channelIds, now: now
            )
            XCTAssertEqual(result.count, 30)
        }
    }

    /// The guide grid's window fetch: every listing (not just now/next) for the
    /// channels on screen, over a 3-hour window.
    func testGuideWindowLoadForVisibleChannels() {
        let channelIds = (0 ..< 30).map { "ch\($0)" }
        let windowStart = epoch.addingTimeInterval(3600)
        let windowEnd = windowStart.addingTimeInterval(3 * 3600)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = EPGGuideLoader.load(
                container: store.container,
                channelIds: channelIds,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            XCTAssertEqual(result.count, 30)
        }
    }

    /// The pathological case the old `@Query` hit on every guide open: the whole
    /// channel set over a wide window. Kept as a benchmark because it is what an
    /// unscoped regression would silently degrade into.
    func testGuideWindowLoadForAllChannels() {
        let channelIds = (0 ..< channelCount).map { "ch\($0)" }
        let windowEnd = epoch.addingTimeInterval(Double(slotsPerChannel) * 1800)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = EPGGuideLoader.load(
                container: store.container,
                channelIds: channelIds,
                windowStart: epoch,
                windowEnd: windowEnd
            )
            XCTAssertEqual(result.count, channelCount)
        }
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
                        listingDescription: "A synthetic description for slot \(slot).",
                        start: start,
                        end: start.addingTimeInterval(1800)
                    ))
                }
            }
        }
        try? context.save()
    }
}
