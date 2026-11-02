import Foundation
import LumeCloudKit
import OSLog
import SwiftData

/// Restores mirror rows that vanished without a recorded deletion.
///
/// A push never infers a tombstone from a missing row, and a pull only sends a
/// record again once its server version moves. So a row deleted without
/// `recordDeletion` or `SyncMirrorDeletionLog`, with its record still marked
/// synced, stayed gone on this device for good: `CloudSyncEngine`'s cleanup of
/// state whose playlist was briefly absent dropped a whole playlist's
/// favorites and category order that way, and builds before the deletion log
/// dropped un-favorites the same way. The last-synced payload is what the
/// server holds, so each such row comes back from it.
extension LumeCloudTransport {
    /// Re-inserts every row whose record synced, isn't pending deletion and
    /// isn't held, but has no mirror row. Content state and category
    /// restrictions come back only while their playlist is in the mirror: the
    /// engine deletes the state of a playlist gone on both sides, and restoring
    /// it would only start that over every pass. Returns how many it restored.
    func restoreUnrecordedRemovals(in context: ModelContext) throws -> Int {
        var playlistIDs: Set<String>?
        var restored = 0
        for modelType in LumeCloudPayloadCodec.mappableModels {
            restored += try restoreRows(of: modelType, playlistIDs: &playlistIDs, in: context)
        }
        if restored > 0 {
            Logger.sync.notice("Lume Cloud restored \(restored) mirror rows removed without a deletion")
        }
        return restored
    }

    private func restoreRows<Model: LumeCloudPayloadMappable>(
        of _: Model.Type,
        playlistIDs: inout Set<String>?,
        in context: ModelContext
    ) throws -> Int {
        let type = Model.lumeCloudType
        let synced = FetchDescriptor<LumeCloudRecordState>(predicate: #Predicate {
            $0.type == type && $0.lastSyncedPayload != nil && !$0.isDeletionPending && $0.undecodableCiphertext == nil
        })
        // Two counts before any row is read: every synced record has a row
        // once the mirror is whole, so fewer rows than records is the only
        // case worth the full read. A new row not pushed yet can hide a lost
        // one for a pass; the push gives it a record and the next pull finds it.
        let syncedCount = try context.fetchCount(synced)
        guard syncedCount > 0, try context.fetchCount(FetchDescriptor<Model>()) < syncedCount else { return 0 }

        let present = try Set(context.fetch(FetchDescriptor<Model>()).map(\.lumeCloudKey))
        var restored = 0
        for state in try context.fetch(synced) where !present.contains(state.logicalKey) {
            guard let bytes = state.lastSyncedPayload,
                  !deletionLog.contains(state.logicalKey),
                  try isRestorable(state.logicalKey, playlistIDs: &playlistIDs, in: context)
            else { continue }
            do {
                try context.insert(LumeCloudPayloadCodec.makeModel(from: LumeCloudPayload.decode(bytes), as: Model.self))
                restored += 1
            } catch {
                Logger.sync.error("Lume Cloud couldn't restore a \(type, privacy: .public) row")
            }
        }
        return restored
    }

    private func isRestorable(_ logicalKey: String, playlistIDs: inout Set<String>?, in context: ModelContext) throws -> Bool {
        let ownerID: String
        switch LumeCloudLogicalKey(logicalKey) {
        case let .content(_, contentId)?: ownerID = String(contentId.prefix(36))
        case let .categoryRestriction(categoryID)?: ownerID = String(categoryID.prefix(36))
        case nil: return false
        default: return true
        }
        if playlistIDs == nil {
            playlistIDs = try Set(context.fetch(FetchDescriptor<SyncedPlaylist>()).map(\.id.uuidString))
        }
        return playlistIDs?.contains(ownerID) == true
    }
}
