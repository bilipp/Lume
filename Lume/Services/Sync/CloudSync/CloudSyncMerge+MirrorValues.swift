import Foundation

// Merge values for the mirror-only collections — profiles, sports follows and
// paired recording servers. They have no local SwiftData counterpart, so the
// iCloud engine only dedupes them; these values exist for a backend that merges
// a remote copy into the mirror (Lume Cloud's pull).
//
// All three share one conflict policy: the newer `updatedAt` wins and the
// remote side wins an exact tie. `updatedAt` is a field (unlike
// `ParentalPINValues`) because the policy cannot be decided without it, and it
// travels in every payload anyway.

// MARK: - Profile

/// The syncable fields of a `UserProfile`. `id` is the identity, not a value.
nonisolated struct ProfileValues: Codable, Equatable {
    var name: String
    var symbolName: String
    var colorRaw: String
    var createdAt: Date
    var sortOrder: Int
    var isChild: Bool
    var updatedAt: Date

    /// Conflict policy: newest `updatedAt` wins, `cloud` wins a tie, and
    /// `isChild == true` on either side always survives — a conflict must never
    /// lift a child restriction.
    static func mergeConflict(local: ProfileValues, cloud: ProfileValues) -> ProfileValues {
        var merged = CloudSyncMirrorMerge.newer(local: local, cloud: cloud, updatedAt: \.updatedAt)
        merged.isChild = local.isChild || cloud.isChild
        return merged
    }
}

// MARK: - Sports follow

/// The syncable fields of a `SyncedSportsFollow`. `key` and `profileID` are the
/// identity, not values.
nonisolated struct SportsFollowValues: Codable, Equatable {
    var kindRaw: String
    var sortOrder: Int
    var updatedAt: Date

    /// Conflict policy: newest `updatedAt` wins, `cloud` wins a tie.
    static func mergeConflict(local: SportsFollowValues, cloud: SportsFollowValues) -> SportsFollowValues {
        CloudSyncMirrorMerge.newer(local: local, cloud: cloud, updatedAt: \.updatedAt)
    }
}

// MARK: - Recording server

/// The syncable fields of a `SyncedRecordingServer`. `id` is the identity, not a
/// value.
nonisolated struct RecordingServerValues: Codable, Equatable {
    var kindRaw: String
    var name: String
    var baseURL: String
    var serverID: UUID?
    var deviceID: UUID?
    var token: String
    var isEnabled: Bool
    var updatedAt: Date

    /// Conflict policy: newest `updatedAt` wins, `cloud` wins a tie. Whole-record,
    /// never field-level: `token` and `deviceID` are only valid as the pair the
    /// server issued together.
    static func mergeConflict(local: RecordingServerValues, cloud: RecordingServerValues) -> RecordingServerValues {
        CloudSyncMirrorMerge.newer(local: local, cloud: cloud, updatedAt: \.updatedAt)
    }
}

nonisolated enum CloudSyncMirrorMerge {
    static func newer<Value>(local: Value, cloud: Value, updatedAt: KeyPath<Value, Date>) -> Value {
        local[keyPath: updatedAt] > cloud[keyPath: updatedAt] ? local : cloud
    }
}
