//
//  CloudSyncTests.swift
//  LumeTests
//
//  Covers the iCloud-sync reconciler: the pure three-way merge (create / update
//  / delete in both directions, conflict policy) and the initial-sync launch
//  gate. Engine end-to-end coverage lives in CloudSyncEngineTests.swift.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Pure three-way merge

struct CloudSyncMergeTests {
    private func merge(
        _ local: Int?, _ cloud: Int?, _ shadow: Int?
    ) -> MergeVerdict<Int> {
        CloudSyncMerge.reconcile(local: local, cloud: cloud, shadow: shadow) { lhs, _ in lhs }
    }

    @Test func `nothing changed is a no-op`() {
        #expect(merge(5, 5, 5) == .noChange)
        #expect(merge(nil, nil, nil) == .noChange)
    }

    @Test func `local create pushes to cloud`() {
        #expect(merge(7, nil, nil) == .pushToCloud(7))
    }

    @Test func `cloud create pulls to local`() {
        #expect(merge(nil, 7, nil) == .pullToLocal(7))
    }

    @Test func `local edit pushes to cloud`() {
        #expect(merge(9, 5, 5) == .pushToCloud(9))
    }

    @Test func `cloud edit pulls to local`() {
        #expect(merge(5, 9, 5) == .pullToLocal(9))
    }

    @Test func `local delete pushes deletion to cloud`() {
        #expect(merge(nil, 5, 5) == .pushToCloud(nil))
    }

    @Test func `cloud delete pulls deletion to local`() {
        #expect(merge(5, nil, 5) == .pullToLocal(nil))
    }

    @Test func `both sides converged on the same value just re-baselines`() {
        #expect(merge(8, 8, 3) == .pushToCloud(8))
    }

    @Test func `genuine conflict invokes the merge closure`() {
        // local edited to 10, cloud edited to 20, base was 5.
        let verdict = CloudSyncMerge.reconcile(local: 10, cloud: 20, shadow: 5) { lhs, rhs in lhs + rhs }
        #expect(verdict == .writeBoth(30))
    }

    @Test func `edit versus delete preserves the surviving edit`() {
        // local edited 5→10, cloud deleted (now nil). Both moved from the base,
        // so it's a conflict; keep the surviving edit (un-delete) on both sides.
        #expect(merge(10, nil, 5) == .writeBoth(10))
        #expect(merge(nil, 10, 5) == .writeBoth(10))
    }
}

// MARK: - Conflict policies

struct CloudSyncConflictPolicyTests {
    @Test func `content conflict keeps furthest progress and merges flags`() {
        let local = ContentStateValues(
            watchProgress: 1200, isWatched: false, lastWatchedDate: Date(timeIntervalSince1970: 100),
            isFavorite: true, addedToWatchlistDate: Date(timeIntervalSince1970: 50), favoriteOrder: nil
        )
        let cloud = ContentStateValues(
            watchProgress: 600, isWatched: true, lastWatchedDate: Date(timeIntervalSince1970: 200),
            isFavorite: false, addedToWatchlistDate: Date(timeIntervalSince1970: 80), favoriteOrder: 3
        )
        let merged = ContentStateValues.mergeConflict(local: local, cloud: cloud)

        #expect(merged.watchProgress == 1200) // furthest
        #expect(merged.isWatched == true) // OR
        #expect(merged.isFavorite == true) // OR (never lose a favorite)
        #expect(merged.lastWatchedDate == Date(timeIntervalSince1970: 200)) // later
        #expect(merged.addedToWatchlistDate == Date(timeIntervalSince1970: 50)) // earliest add
        #expect(merged.favoriteOrder == 3) // local nil → cloud
    }

    @Test func `recommendation vote conflict resolves an up-down clash to not-interested`() {
        let upvoted = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil,
            recommendationVoteRaw: RecommendationVote.upvote.rawValue
        )
        let downvoted = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil,
            recommendationVoteRaw: RecommendationVote.downvote.rawValue
        )
        // Up/down clash → keep "not interested".
        #expect(ContentStateValues.mergeConflict(local: upvoted, cloud: downvoted).recommendationVoteRaw == RecommendationVote.downvote.rawValue)
        // An explicit vote beats none.
        let unvoted = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        #expect(ContentStateValues.mergeConflict(local: unvoted, cloud: upvoted).recommendationVoteRaw == RecommendationVote.upvote.rawValue)
    }

    @Test func `playlist conflict resolves last-write-wins favouring cloud`() {
        let local = PlaylistConfigValues(
            name: "Local", serverURL: "a", username: "u", password: "p",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        )
        let cloud = PlaylistConfigValues(
            name: "Cloud", serverURL: "b", username: "u2", password: "p2",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: false
        )
        #expect(PlaylistConfigValues.mergeConflict(local: local, cloud: cloud) == cloud)
    }

    @Test func `empty content state is treated as absent`() {
        let empty = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        #expect(empty.isEmpty)
    }

    @Test func `a hidden or reordered item carries state and is not empty`() {
        var hidden = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        hidden.isHidden = true
        #expect(!hidden.isEmpty)

        var ordered = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        ordered.customOrder = 3
        #expect(!ordered.isEmpty)
    }

    @Test func `content management conflict keeps a hide and a concrete order`() {
        var local = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        local.isHidden = true
        local.customOrder = nil
        var cloud = ContentStateValues(
            watchProgress: 0, isWatched: false, lastWatchedDate: nil,
            isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        cloud.isHidden = false
        cloud.customOrder = 5

        let merged = ContentStateValues.mergeConflict(local: local, cloud: cloud)
        #expect(merged.isHidden == true) // union — either side hiding wins
        #expect(merged.customOrder == 5) // local nil → cloud's concrete order
    }

    @Test func `content state decodes a baseline written before hide and order existed`() throws {
        // A shadow baseline persisted before these fields shipped has no
        // `isHidden` / `customOrder` keys — it must still decode to defaults.
        let legacy = #"{"watchProgress":0,"isWatched":false,"isFavorite":true}"#
        let decoded = try JSONDecoder().decode(ContentStateValues.self, from: Data(legacy.utf8))
        #expect(decoded.isFavorite)
        #expect(decoded.isHidden == false)
        #expect(decoded.customOrder == nil)
    }
}

// MARK: - Initial-sync launch gate

/// The launch gate (`status.hasCompletedInitialSync`) that a fresh install waits
/// on before showing the add-playlist form. The actual wait fires only when
/// CloudKit is enabled, which can't run in an un-entitled test binary (it
/// crashes — the very reason `cloudKitEnabled` exists), so this covers the
/// disabled path that previews, unit tests and UI tests take: the gate must be
/// open from the start so the form stays reachable on an empty store.
@MainActor
struct CloudSyncInitialGateTests {
    @Test func `gate is open from init when CloudKit is disabled`() throws {
        // The coordinator's engine only opens a ModelContext at init (it never
        // fetches) and the CloudKit-disabled path returns before touching the
        // cloud store, so the shared catalog container is enough here.
        let container = try makeTestContainer()
        let coordinator = CloudSyncCoordinator(
            catalogContainer: container,
            cloudContainer: container,
            cloudKitContainerIdentifier: "iCloud.test",
            cloudKitEnabled: false
        )
        #expect(coordinator.status.hasCompletedInitialSync)
    }
}
