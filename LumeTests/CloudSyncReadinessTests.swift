//
//  CloudSyncReadinessTests.swift
//  LumeTests
//
//  Covers the local-catalog integrity gate's count classification (#256): a
//  detached store can report `NSNotFound` as a count without throwing, which
//  used to trap on overflow when the counts were summed after sleep/wake.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct CloudSyncReadinessTests {
    @Test func `NSNotFound counts read as unreadable instead of trapping`() {
        let counts = [NSNotFound, NSNotFound, 0, NSNotFound, 12]
        #expect(CloudSyncEngine.readiness(counts: counts, shadowHasBaseline: true) == .unreadable)
        #expect(CloudSyncEngine.readiness(counts: counts, shadowHasBaseline: false) == .unreadable)
    }

    @Test func `negative counts read as unreadable`() {
        #expect(CloudSyncEngine.readiness(counts: [1, -1, 0, 0, 0], shadowHasBaseline: false) == .unreadable)
    }

    @Test func `an empty catalog with a shadow baseline is a lost store`() {
        #expect(CloudSyncEngine.readiness(counts: [0, 0, 0, 0, 0], shadowHasBaseline: true) == .emptiedButHadData)
    }

    @Test func `an empty catalog without a baseline is a fresh device`() {
        #expect(CloudSyncEngine.readiness(counts: [0, 0, 0, 0, 0], shadowHasBaseline: false) == .ready)
    }

    @Test func `huge but valid counts are ready`() {
        let counts = [3, Int.max / 4, Int.max / 4, Int.max / 4, Int.max / 4]
        #expect(CloudSyncEngine.readiness(counts: counts, shadowHasBaseline: true) == .ready)
    }
}
