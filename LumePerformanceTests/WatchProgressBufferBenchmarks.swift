//
//  WatchProgressBufferBenchmarks.swift
//  LumePerformanceTests
//
//  The cost of the player's periodic watch-progress sample.
//
//  The 30 s sampler was switched off once to spare KSPlayer, and Apple TV users
//  paid for it with lost resume points. These pin down what one sample costs on
//  each side of the hop, so the trade can be judged on numbers: the player
//  calls `record` from the main actor, where KSPlayer presents frames, and the
//  `UserDefaults` write runs on the buffer's `.background` queue.
//
//  Each measured block runs `samples` operations; divide by it for one sample.
//  Every value is distinct so the paused-playback dedup never short-circuits.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class WatchProgressBufferBenchmarks: XCTestCase {
    private let samples = 1000
    private let duration: TimeInterval = 5400

    override func setUp() {
        super.setUp()
        _ = WatchProgressBuffer.drain()
    }

    override func tearDown() {
        _ = WatchProgressBuffer.drain()
        super.tearDown()
    }

    /// What the main actor pays per sample: building the key and enqueueing.
    /// `drain()` is outside the measured block but waits out the queue, so the
    /// next iteration never measures behind a backlog.
    func testSampleCallerCost() {
        var base: TimeInterval = 1
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for offset in 0 ..< samples {
                WatchProgressBuffer.record(
                    ref: .movie("perf-movie"),
                    progress: base + TimeInterval(offset),
                    duration: duration
                )
            }
            base += TimeInterval(samples)
        }
        _ = WatchProgressBuffer.drain()
    }

    /// One sample end to end: enqueue, hop to the queue, write `UserDefaults`.
    /// This is the work the background queue does every 30 s during playback,
    /// and what the leaving-foreground flush blocks the main actor on, once.
    func testSampleWriteCost() {
        var base: TimeInterval = 1
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for offset in 0 ..< samples {
                WatchProgressBuffer.record(
                    ref: .episode("perf-episode"),
                    progress: base + TimeInterval(offset),
                    duration: duration,
                    waitUntilWritten: true
                )
            }
            base += TimeInterval(samples)
        }
    }

    /// The commit that a buffered sample stands in for: `reconcilePending`
    /// writing one position into an on-disk catalog. Runs once per launch after
    /// a killed session, never during playback.
    func testLaunchRecoveryCommit() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let context = ModelContext(store.container)
        context.insert(Movie(id: "perf-movie", streamId: 1, name: "Film"))
        try context.save()

        var progress: TimeInterval = 1
        measure(metrics: [XCTClockMetric()]) {
            WatchProgressBuffer.record(
                ref: .movie("perf-movie"), progress: progress, duration: duration, waitUntilWritten: true
            )
            progress += 1
            let done = expectation(description: "reconciled")
            Task {
                await WatchProgressWriter.reconcilePending(container: store.container)
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }
    }
}
