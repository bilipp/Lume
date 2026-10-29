import Foundation
import LumeCloudKit
import SwiftData

/// The mirror-only rows of one mirror store, in wire form: the data no catalog
/// projection can rebuild after a backend switch.
nonisolated struct SyncMirrorSnapshot {
    var payloads: [LumeCloudPayload]
}

/// Carries mirror-only data across a backend switch: every profile, sports
/// follow and paired recording server, and the content state of the profiles
/// that aren't active (the active one's is re-projected from the catalog by the
/// first reconcile). A union: rows the target lacks are inserted, rows it has
/// are merged with the collection's conflict rule, the copied side standing in
/// for the remote one.
///
/// Snapshot and seed are separate so a Lume Cloud rejoin can empty its store in
/// between, even when that store is also the source.
nonisolated enum SyncMirrorSeeder {
    static func snapshot(of container: ModelContainer, activeProfileID: UUID) async throws -> SyncMirrorSnapshot {
        try await Task.detached {
            let context = ModelContext(container)
            var payloads: [LumeCloudPayload] = []
            try payloads += Self.payloads(UserProfile.self, in: context)
            try payloads += Self.payloads(SyncedSportsFollow.self, in: context)
            try payloads += Self.payloads(SyncedRecordingServer.self, in: context)
            // A nil profile is the default one; `??` crashes SwiftData's SQL generation.
            let includeUnclaimed = activeProfileID != UserProfile.defaultProfileID
            try payloads += Self.payloads(
                UserContentState.self,
                in: context,
                where: #Predicate {
                    ($0.profileID != nil && $0.profileID != activeProfileID) || ($0.profileID == nil && includeUnclaimed)
                }
            )
            return SyncMirrorSnapshot(payloads: payloads)
        }.value
    }

    /// Writes `snapshot` into `container`; returns how many rows it inserted.
    @discardableResult
    static func seed(_ snapshot: SyncMirrorSnapshot, into container: ModelContainer) async throws -> Int {
        guard !snapshot.payloads.isEmpty else { return 0 }
        return try await Task.detached {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let byType = Dictionary(grouping: snapshot.payloads, by: \.type)
            var inserted = 0
            for (type, payloads) in byType {
                guard let modelType = LumeCloudPayloadCodec.mergingModelType(forRecordType: type) else { continue }
                inserted += try Self.seed(payloads, as: modelType, in: context)
            }
            if context.hasChanges {
                try context.save()
            }
            return inserted
        }.value
    }

    private static func payloads<Model: LumeCloudPayloadMappable>(
        _: Model.Type,
        in context: ModelContext,
        where predicate: Predicate<Model>? = nil
    ) throws -> [LumeCloudPayload] {
        try context.fetch(FetchDescriptor<Model>(predicate: predicate))
            .map { LumeCloudPayloadCodec.payload(for: $0, previous: nil) }
    }

    private static func seed<Model: LumeCloudConflictMerging>(
        _ payloads: [LumeCloudPayload],
        as _: Model.Type,
        in context: ModelContext
    ) throws -> Int {
        var existing: [String: Model] = [:]
        for row in try context.fetch(FetchDescriptor<Model>()) where existing[row.lumeCloudKey] == nil {
            existing[row.lumeCloudKey] = row
        }
        var inserted = 0
        for payload in payloads {
            guard let copy = try? LumeCloudPayloadCodec.makeModel(from: payload, as: Model.self) else { continue }
            if let row = existing[payload.key] {
                try row.mergeLumeCloudConflict(with: copy)
            } else {
                context.insert(copy)
                existing[payload.key] = copy
                inserted += 1
            }
        }
        return inserted
    }
}
