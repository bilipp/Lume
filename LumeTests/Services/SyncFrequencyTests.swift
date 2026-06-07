//
//  SyncFrequencyTests.swift
//  LumeTests
//
//  Covers the staleness logic and the auto-sync decision gate behind issue #22's
//  automatic content sync.
//

import Foundation
@testable import Lume
import Testing

struct SyncFrequencyTests {
    // MARK: - Defaults & resolution

    @Test func `default is every three days`() {
        #expect(SyncFrequency.defaultValue == .everyThreeDays)
    }

    @Test func `resolve falls back to default for unknown raw`() {
        #expect(SyncFrequency.resolve("") == .defaultValue)
        #expect(SyncFrequency.resolve("nonsense") == .defaultValue)
        #expect(SyncFrequency.resolve("weekly") == .weekly)
    }

    @Test func `intervals match advertised frequencies`() {
        #expect(SyncFrequency.sixHours.interval == 6 * 3600)
        #expect(SyncFrequency.daily.interval == 24 * 3600)
        #expect(SyncFrequency.everyThreeDays.interval == 3 * 24 * 3600)
        #expect(SyncFrequency.weekly.interval == 7 * 24 * 3600)
    }

    // MARK: - isDue

    @Test func `never synced is always due`() {
        for frequency in SyncFrequency.allCases {
            #expect(frequency.isDue(lastSyncDate: nil))
        }
    }

    @Test func `recent sync is not due`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneHourAgo = now.addingTimeInterval(-3600)
        #expect(SyncFrequency.sixHours.isDue(lastSyncDate: oneHourAgo, now: now) == false)
        #expect(SyncFrequency.weekly.isDue(lastSyncDate: oneHourAgo, now: now) == false)
    }

    @Test func `stale sync is due`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sevenHoursAgo = now.addingTimeInterval(-7 * 3600)
        #expect(SyncFrequency.sixHours.isDue(lastSyncDate: sevenHoursAgo, now: now))
        #expect(SyncFrequency.daily.isDue(lastSyncDate: sevenHoursAgo, now: now) == false)
    }

    @Test func `due exactly at the interval boundary`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exactlyDaily = now.addingTimeInterval(-SyncFrequency.daily.interval)
        #expect(SyncFrequency.daily.isDue(lastSyncDate: exactlyDaily, now: now))
    }

    // MARK: - AutoSync.shouldSync

    @Test func `auto-sync triggers for a due enabled idle playlist`() {
        #expect(AutoSync.shouldSync(
            syncEnabled: true,
            status: .idle,
            lastSyncDate: nil,
            frequency: .everyThreeDays,
            alreadyStarted: false
        ))
    }

    @Test func `auto-sync skips when sync disabled`() {
        #expect(AutoSync.shouldSync(
            syncEnabled: false,
            status: .idle,
            lastSyncDate: nil,
            frequency: .everyThreeDays,
            alreadyStarted: false
        ) == false)
    }

    @Test func `auto-sync skips while already syncing`() {
        #expect(AutoSync.shouldSync(
            syncEnabled: true,
            status: .syncing,
            lastSyncDate: nil,
            frequency: .everyThreeDays,
            alreadyStarted: false
        ) == false)
    }

    @Test func `auto-sync skips when already started this session`() {
        #expect(AutoSync.shouldSync(
            syncEnabled: true,
            status: .idle,
            lastSyncDate: nil,
            frequency: .everyThreeDays,
            alreadyStarted: true
        ) == false)
    }

    @Test func `auto-sync skips when not yet due`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = now.addingTimeInterval(-3600)
        #expect(AutoSync.shouldSync(
            syncEnabled: true,
            status: .idle,
            lastSyncDate: recent,
            frequency: .everyThreeDays,
            alreadyStarted: false,
            now: now
        ) == false)
    }

    @Test func `auto-sync triggers after error when due`() {
        // A previous failure leaves status == .error; it should still re-sync.
        #expect(AutoSync.shouldSync(
            syncEnabled: true,
            status: .error,
            lastSyncDate: nil,
            frequency: .everyThreeDays,
            alreadyStarted: false
        ))
    }
}
