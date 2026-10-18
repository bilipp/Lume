//
//  PlaylistBatchSelectionTests.swift
//  LumeTests
//
//  Covers which playlists "Sync Out-of-Date Playlists" picks up
//  (`PlaylistBatchSelection.resolve`), and when it falls back to Sync All.
//

import Foundation
@testable import Lume
import Testing

struct PlaylistBatchSelectionTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let active = UUID()
    private let other = UUID()
    private let third = UUID()

    @Test func `only the stale playlists are picked when any are stale`() {
        let selection = PlaylistBatchSelection.resolve([
            (active, .synced(lastSyncDate: date), true),
            (other, .awaitingSelection(lastSyncDate: date), false),
            (third, .failed, false)
        ])
        #expect(selection == .outOfDate([other, third]))
    }

    @Test func `the active playlist goes first`() {
        let selection = PlaylistBatchSelection.resolve([
            (other, .never, false),
            (active, .overdue(lastSyncDate: date), true)
        ])
        #expect(selection == .outOfDate([active, other]))
    }

    @Test func `a playlist with sync turned off is never picked`() {
        let selection = PlaylistBatchSelection.resolve([
            (active, .synced(lastSyncDate: date), true),
            (other, .disabled(lastSyncDate: date), false)
        ])
        #expect(selection == .all([active]))
    }

    @Test func `one already syncing is left alone`() {
        let selection = PlaylistBatchSelection.resolve([
            (active, .syncing, true),
            (other, .never, false)
        ])
        #expect(selection == .outOfDate([other]))
    }

    @Test func `with everything fresh it offers to sync them all`() {
        let selection = PlaylistBatchSelection.resolve([
            (active, .synced(lastSyncDate: date), true),
            (other, .synced(lastSyncDate: date), false)
        ])
        #expect(selection == .all([active, other]))
    }

    @Test func `nothing eligible means nothing to do`() {
        let selection = PlaylistBatchSelection.resolve([
            (active, .syncing, true),
            (other, .disabled(lastSyncDate: nil), false)
        ])
        #expect(selection == .none)
        #expect(selection.ids.isEmpty)
    }
}
