//
//  CloudSyncCoordinator+SyncNow.swift
//  Lume
//
//  Settings ▸ Sync's Sync Now: one pass right away on the active backend.
//

import Foundation

extension CloudSyncCoordinator {
    /// Whether the active backend has anything a manual sync can reach: an
    /// available iCloud account, or a Lume Cloud membership.
    var canSyncNow: Bool {
        switch selectedBackend {
        case .icloud:
            status.account == .available
        case .lumecloud:
            switch status.lumeCloud {
            case .notJoined, .revoked, .accountDeleted: false
            case .joined, .syncing, .uploading, .rateLimited, .quotaExceeded, .offline: true
            }
        case .off:
            false
        }
    }

    /// Lets an in-flight pass finish, then runs one more without the debounce
    /// or the "nothing pending" skip: Lume Cloud pulls and pushes, and iCloud
    /// reconciles whatever CloudKit has imported. CloudKit's own import/export
    /// has no public trigger, so the iCloud pass works from what is local.
    func syncNow() async {
        guard backend.kind != nil, !isSyncingNow else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        await waitForPass()
        reconcile(reason: .manual, debounced: false)
        await waitForPass()
    }
}
