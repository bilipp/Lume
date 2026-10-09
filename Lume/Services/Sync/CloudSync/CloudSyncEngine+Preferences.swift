//
//  CloudSyncEngine+Preferences.swift
//  Lume
//
//  Reconciles the account-wide Live TV rail switches (Settings › Live TV ›
//  Categories) with their `SyncedLiveTVPreferences` mirror. The same three-way
//  merge over a shadow baseline as the parental PIN: UserDefaults is the local
//  store of record, the CloudKit record only carries the value between devices.
//

import Foundation
import SwiftData

extension CloudSyncEngine {
    func reconcileLiveTVPreferences(into result: inout CloudSyncReconcileResult) throws {
        let mirror = try fetchLiveTVPreferencesMirror()
        let verdict = CloudSyncMerge.reconcile(
            local: LiveTVRailSettings.storedValues(in: preferences),
            cloud: mirror.map {
                LiveTVPreferenceValues(showsFavorites: $0.showsFavorites, showsRecentlyWatched: $0.showsRecentlyWatched)
            },
            shadow: shadow.liveTVPreferencesShadow(),
            mergeConflict: LiveTVPreferenceValues.mergeConflict
        )

        switch verdict {
        case .noChange:
            return
        case let .pushToCloud(value):
            applyLiveTVPreferencesToCloud(value, mirror: mirror)
            if value != nil { result.preferencesPushed += 1 }
            shadow.setLiveTVPreferencesShadow(value)
        case let .pullToLocal(value):
            LiveTVRailSettings.store(value, in: preferences)
            result.preferencesPulled += 1
            shadow.setLiveTVPreferencesShadow(value)
        case let .writeBoth(value):
            LiveTVRailSettings.store(value, in: preferences)
            applyLiveTVPreferencesToCloud(value, mirror: mirror)
            result.preferencesPushed += 1
            shadow.setLiveTVPreferencesShadow(value)
        }
    }

    private func applyLiveTVPreferencesToCloud(_ value: LiveTVPreferenceValues?, mirror: SyncedLiveTVPreferences?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        guard let mirror else {
            cloudContext.insert(SyncedLiveTVPreferences(
                showsFavorites: value.showsFavorites,
                showsRecentlyWatched: value.showsRecentlyWatched
            ))
            return
        }
        // Only stamp `updatedAt` on a real change: it is the dedupe tie-break.
        guard mirror.showsFavorites != value.showsFavorites
            || mirror.showsRecentlyWatched != value.showsRecentlyWatched else { return }
        mirror.showsFavorites = value.showsFavorites
        mirror.showsRecentlyWatched = value.showsRecentlyWatched
        mirror.updatedAt = Date()
    }

    /// The preferences mirror, collapsing any duplicate singletons two devices
    /// inserted before they converged.
    private func fetchLiveTVPreferencesMirror() throws -> SyncedLiveTVPreferences? {
        var winner: SyncedLiveTVPreferences?
        for record in try cloudContext.fetch(FetchDescriptor<SyncedLiveTVPreferences>()) {
            winner = dedupe(record, against: winner, updatedAt: \.updatedAt)
        }
        return winner
    }
}
