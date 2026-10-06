//
//  CloudSyncEngine+RecordingServers.swift
//  Lume
//
//  The recording-server reconcile step. `SyncedRecordingServer` has no local
//  SwiftData counterpart — the app reads it straight off the cloud context — so
//  this is not a three-way merge: it only collapses duplicate rows for one
//  server, the same defensive de-dup the sports follows get.
//

import Foundation
import SwiftData

extension CloudSyncEngine {
    /// Collapse duplicate recording-server records for one server. Keeps the
    /// most recently updated and deletes the rest. Keyed on `serverID`, not the
    /// random row `id`: two devices pairing the same server (or a re-pair before
    /// the first row synced) write rows with different ids for one server.
    func reconcileRecordingServers(into result: inout CloudSyncReconcileResult) throws {
        (result.recordingServersKept, result.recordingServersDeduped) = try collapseDuplicates(
            SyncedRecordingServer.self,
            key: { $0.serverID?.uuidString ?? $0.id.uuidString },
            updatedAt: \.updatedAt
        )
    }
}
