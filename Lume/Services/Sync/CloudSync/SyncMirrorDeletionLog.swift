//
//  SyncMirrorDeletionLog.swift
//  Lume
//
//  The logical keys of mirror rows deleted on purpose, between the delete and
//  the next pass. Lume Cloud never infers a deletion from a missing row
//  (PROTOCOL.md §6.4), so a row a writer removes has to be reported, or the
//  server keeps the old record and the other devices never see the change.
//

import Foundation
import os
import SwiftData

/// Mirror rows deleted on purpose: an un-favorite, a cleared PIN, an unfollowed
/// team, a forgotten recording server. Every writer that means a deletion goes
/// through `delete(_:in:)`; the coordinator drains the keys into the active
/// backend at each pass, where Lume Cloud turns them into tombstones and iCloud,
/// which exports row deletions on its own, ignores them.
///
/// Deletions that aren't meant to propagate stay plain `ModelContext.delete`:
/// collapsing a duplicate (its survivor keeps the key) and the garbage
/// collection of state whose playlist is gone on both sides. A playlist that is
/// only briefly absent must not turn its favorites into server-wide tombstones;
/// the transport restores such rows once the playlist is back
/// (`LumeCloudTransport.restoreUnrecordedRemovals`).
///
/// In memory only: a deletion lost to a crash before the next pass comes back
/// from the server, which still holds it — the conservative failure.
final nonisolated class SyncMirrorDeletionLog: Sendable {
    static let shared = SyncMirrorDeletionLog()

    private let keys = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Deletes `row` from `context` and records its key.
    func delete(_ row: some LumeCloudPayloadMappable, in context: ModelContext) {
        record(row.lumeCloudKey)
        context.delete(row)
    }

    func record(_ key: String) {
        keys.withLock { _ = $0.insert(key) }
    }

    /// Whether `key` waits for the next pass.
    func contains(_ key: String) -> Bool {
        keys.withLock { $0.contains(key) }
    }

    /// Every recorded key, emptying the log.
    func drain() -> [String] {
        keys.withLock { keys in
            defer { keys.removeAll() }
            return Array(keys)
        }
    }
}
