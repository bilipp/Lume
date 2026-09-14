//
//  PlaylistSyncStateTests.swift
//  LumeTests
//
//  Covers how a playlist's stored fields resolve into the state the settings
//  surfaces render (`PlaylistSyncState.resolve`), including the two cases the
//  detail panes used to show as no row at all: never synced, and failed.
//

import Foundation
@testable import Lume
import Testing

struct PlaylistSyncStateTests {
    private let frequency = SyncFrequency.everyThreeDays
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func resolve(
        syncEnabled: Bool = true,
        status: SyncStatus = .idle,
        lastSyncDate: Date?
    ) -> PlaylistSyncState {
        PlaylistSyncState.resolve(
            syncEnabled: syncEnabled,
            status: status,
            lastSyncDate: lastSyncDate,
            frequency: frequency,
            now: now
        )
    }

    // MARK: - Resolution

    @Test func `a playlist that has never synced reads as never, not as up to date`() {
        #expect(resolve(lastSyncDate: nil) == .never)
    }

    @Test func `an errored playlist reads as failed even though it synced before`() {
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)
        #expect(resolve(status: .error, lastSyncDate: yesterday) == .failed)
    }

    @Test func `a running sync outranks everything else`() {
        #expect(resolve(status: .syncing, lastSyncDate: nil) == .syncing)
    }

    @Test func `a manual sync shows as syncing even with automatic sync off`() {
        #expect(resolve(syncEnabled: false, status: .syncing, lastSyncDate: nil) == .syncing)
    }

    @Test func `an opted-out playlist reads as disabled rather than stale`() {
        let longAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)
        #expect(resolve(syncEnabled: false, lastSyncDate: longAgo) == .disabled(lastSyncDate: longAgo))
    }

    // MARK: - The interval boundary

    @Test func `synced inside the interval is up to date`() {
        let recent = now.addingTimeInterval(-frequency.interval + 60)
        #expect(resolve(lastSyncDate: recent) == .synced(lastSyncDate: recent))
    }

    @Test func `synced exactly at the interval is already overdue`() {
        let boundary = now.addingTimeInterval(-frequency.interval)
        #expect(resolve(lastSyncDate: boundary) == .overdue(lastSyncDate: boundary))
    }

    // MARK: - Presentation

    @Test func `only the states worth acting on draw a row accessory`() {
        let date = now.addingTimeInterval(-60)
        #expect(PlaylistSyncState.syncing.deservesRowAccessory)
        #expect(PlaylistSyncState.failed.deservesRowAccessory)
        #expect(PlaylistSyncState.never.deservesRowAccessory)
        #expect(!PlaylistSyncState.synced(lastSyncDate: date).deservesRowAccessory)
        #expect(!PlaylistSyncState.overdue(lastSyncDate: date).deservesRowAccessory)
        #expect(!PlaylistSyncState.disabled(lastSyncDate: date).deservesRowAccessory)
    }

    @Test func `states without a successful sync carry no date to show`() {
        #expect(PlaylistSyncState.never.lastSyncDate == nil)
        #expect(PlaylistSyncState.failed.lastSyncDate == nil)
        #expect(PlaylistSyncState.syncing.lastSyncDate == nil)
    }

    @Test func `states with a successful sync carry the date through`() {
        let date = now.addingTimeInterval(-60)
        #expect(PlaylistSyncState.synced(lastSyncDate: date).lastSyncDate == date)
        #expect(PlaylistSyncState.overdue(lastSyncDate: date).lastSyncDate == date)
        #expect(PlaylistSyncState.disabled(lastSyncDate: date).lastSyncDate == date)
    }
}
