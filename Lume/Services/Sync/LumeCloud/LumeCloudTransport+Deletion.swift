import Foundation
import LumeCloudKit
import SwiftData

/// Recorded user deletions: the only source of the tombstones a push sends.
extension LumeCloudTransport {
    /// Records that the user deleted the record under `logicalKey`: removes its
    /// mirror row and queues a tombstone for the next push. The only way a push
    /// deletes a server record. A key this build can't parse, or a record that
    /// never synced, queues nothing.
    func recordDeletion(logicalKey: String) async throws {
        try await recordDeletions(logicalKeys: [logicalKey])
    }

    /// `recordDeletion(logicalKey:)` for several records in one store write.
    func recordDeletions(logicalKeys: [String]) async throws {
        guard !logicalKeys.isEmpty else { return }
        try await serialized { transport in
            transport.liftQuotaHold()
            if try transport.performRecordDeletions(logicalKeys: logicalKeys) {
                await transport.postMirrorDidChange()
            }
        }
    }

    /// The logical keys of every synced record, not already queued for
    /// deletion, whose key contains any of `fragments`. Callers still match
    /// the parsed key: a fragment only narrows the read.
    func syncedLogicalKeys(containing fragments: [String]) async throws -> [String] {
        try await serialized { transport in
            let context = transport.makeContext()
            var keys: Set<String> = []
            for fragment in fragments {
                var descriptor = FetchDescriptor<LumeCloudRecordState>(
                    predicate: #Predicate {
                        !$0.isDeletionPending && $0.lastSyncedPayload != nil && $0.logicalKey.contains(fragment)
                    }
                )
                descriptor.propertiesToFetch = [\.logicalKey]
                try keys.formUnion(context.fetch(descriptor).map(\.logicalKey))
            }
            return Array(keys)
        }
    }

    private func performRecordDeletions(logicalKeys: [String]) throws -> Bool {
        var keysByModel: [ObjectIdentifier: (model: any LumeCloudPayloadMappable.Type, keys: Set<String>)] = [:]
        for logicalKey in logicalKeys {
            guard let key = LumeCloudLogicalKey(logicalKey) else { continue }
            let modelType = key.modelType
            keysByModel[ObjectIdentifier(modelType), default: (modelType, [])].keys.insert(logicalKey)
        }
        guard !keysByModel.isEmpty else { return false }
        let context = makeContext()
        var deletedRow = false
        for entry in keysByModel.values {
            deletedRow = try deleteRows(under: entry.keys, as: entry.model, in: context) || deletedRow
        }
        let rids = keysByModel.values.flatMap(\.keys).map { keys.recordID(for: $0) }
        let descriptor = FetchDescriptor<LumeCloudRecordState>(predicate: #Predicate { rids.contains($0.rid) })
        for state in try context.fetch(descriptor) where state.lastSyncedPayload != nil {
            update(state, \.isDeletionPending, to: true)
            update(state, \.isDirty, to: true)
        }
        if context.hasChanges {
            try context.save()
        }
        return deletedRow
    }

    private func deleteRows<Model: LumeCloudPayloadMappable>(
        under keys: Set<String>,
        as _: Model.Type,
        in context: ModelContext
    ) throws -> Bool {
        let rows = try mirrorRows(Model.self, withKeys: keys, in: context).filter { keys.contains($0.lumeCloudKey) }
        for row in rows {
            context.delete(row)
        }
        return !rows.isEmpty
    }
}
