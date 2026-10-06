//
//  CloudSyncEngine+Sports.swift
//  Lume
//
//  The sports-follow reconcile step and its profile-purge helper, split out of
//  CloudSyncEngine to keep that file within the project's line-count cap.
//
//  Unlike playlists / content / EPG sources, `SyncedSportsFollow` has no local
//  SwiftData counterpart — the hub reads follows through `SportsFollowService`
//  directly over the cloud context. So this is not a three-way merge: it is a
//  pure cloud-side dedupe that collapses duplicate rows CloudKit surfaced for one
//  (key, profile) pair, the same defensive de-dup applied to the other mirrors.
//

import Foundation
import SwiftData

extension CloudSyncEngine {
    /// Collapse duplicate sports-follow records sharing a (`key`, `profileID`)
    /// pair. CloudKit keys records by its own identifier, not our fields, so two
    /// devices that each follow the same league before syncing produce two rows
    /// for one follow. Keeps the most recently updated (cloud-wins tie-break) and
    /// deletes the rest.
    func reconcileSportsFollows(into result: inout CloudSyncReconcileResult) throws {
        (result.sportsFollowsKept, result.sportsFollowsDeduped) = try collapseDuplicates(
            SyncedSportsFollow.self,
            key: { "\($0.key)|\($0.profileID?.uuidString ?? "nil")" },
            updatedAt: \.updatedAt
        )
    }

    /// Delete every sports-follow record owned by a profile (called when the
    /// profile itself is deleted). A `nil` profileID counts as the default
    /// profile, mirroring `UserContentState`, so it is removed only when purging
    /// the default.
    func purgeSportsFollows(forProfile profileID: UUID) throws {
        let isDefault = profileID == UserProfile.defaultProfileID
        let descriptor = FetchDescriptor<SyncedSportsFollow>(
            predicate: #Predicate {
                $0.profileID == profileID || (isDefault && $0.profileID == nil)
            }
        )
        for follow in try cloudContext.fetch(descriptor) {
            cloudContext.delete(follow)
        }
    }
}
