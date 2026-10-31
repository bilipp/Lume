import Foundation
import LumeCloudKit
import SwiftData

/// Pulled records merged into the mirror: the server value against the local
/// row, over the last-synced payload as the base.
extension LumeCloudTransport {
    /// Merges every record of one collection into the mirror: the server value
    /// against the local mirror row, over the last-synced payload as the base.
    func merge<Model: LumeCloudConflictMerging>(
        _ records: [PulledRecord],
        as _: Model.Type,
        states: inout [String: LumeCloudRecordState],
        in context: ModelContext
    ) throws -> (changed: Bool, skipped: Int) {
        var rows = try Dictionary(
            mirrorRows(Model.self, withKeys: Set(records.map(\.key)), in: context).map { ($0.lumeCloudKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = false
        var skipped = 0
        for record in records {
            var probe: Model?
            if let payload = record.payload {
                probe = try? LumeCloudPayloadCodec.makeModel(from: payload, as: Model.self)
                guard probe != nil else {
                    hold(record.remote, key: record.key, type: record.type, states: &states, in: context)
                    skipped += 1
                    continue
                }
            }
            let base = states[record.rid]?.lastSyncedPayload
            let local = rows[record.key]
            let localBytes = try local.map { try LumeCloudPayloadCodec.encoded($0, previous: base) }
            let verdict = CloudSyncMerge.reconcile(local: localBytes, cloud: record.bytes, shadow: base) { localPayload, remotePayload in
                (try? Self.mergedPayload(local: localPayload, remote: remotePayload, as: Model.self)) ?? remotePayload
            }
            let result: Data? = switch verdict {
            case .noChange: localBytes
            case let .pushToCloud(value), let .pullToLocal(value): value
            case let .writeBoth(value): value
            }
            if result != localBytes {
                try write(result, pulled: record, probe: probe, rows: &rows, in: context)
                changed = true
            }
            let state = recordState(rid: record.rid, key: record.key, type: record.type, states: &states, in: context)
            update(state, \.version, to: record.version)
            update(state, \.lastSyncedPayload, to: record.bytes)
            update(state, \.isDirty, to: result != record.bytes)
            release(state)
        }
        return (changed, skipped)
    }

    /// Both sides changed the record differently: the collection's conflict
    /// policy decides. Fields only the server's payload carries survive.
    nonisolated static func mergedPayload<Model: LumeCloudConflictMerging>(
        local: Data,
        remote: Data,
        as _: Model.Type
    ) throws -> Data {
        let localModel = try LumeCloudPayloadCodec.makeModel(from: LumeCloudPayload.decode(local), as: Model.self)
        let remoteModel = try LumeCloudPayloadCodec.makeModel(from: LumeCloudPayload.decode(remote), as: Model.self)
        try localModel.mergeLumeCloudConflict(with: remoteModel)
        return try LumeCloudPayloadCodec.encoded(localModel, previous: remote)
    }

    /// Writes `result` over the mirror row under `record`'s key. `probe` is the
    /// uninserted model built from `record`'s payload, inserted as is when
    /// `result` is that payload.
    private func write<Model: LumeCloudConflictMerging>(
        _ result: Data?,
        pulled record: PulledRecord,
        probe: Model?,
        rows: inout [String: Model],
        in context: ModelContext
    ) throws {
        let local = rows[record.key]
        guard let result else {
            if let local {
                context.delete(local)
                rows[record.key] = nil
            }
            return
        }
        let pulledPayload = result == record.bytes ? record.payload : nil
        let payload = try pulledPayload ?? LumeCloudPayload.decode(result)
        if let local {
            try LumeCloudPayloadCodec.apply(payload, to: local)
        } else {
            let model = try (pulledPayload == nil ? nil : probe) ?? LumeCloudPayloadCodec.makeModel(from: payload, as: Model.self)
            context.insert(model)
            rows[record.key] = model
        }
    }
}
