import Foundation
import SwiftData

/// The recording-server backends Lume knows how to talk to.
nonisolated enum RecordingServerKind: String, CaseIterable {
    case lumeRecorder
}

/// CloudKit-synced configuration of one paired DVR / recording server.
///
/// Account-wide (no `profileID`): the pairing token syncs, so every device the
/// user owns shares the one pairing. There is no local SwiftData counterpart and
/// recordings themselves are never persisted — the app reads this through a
/// service over the cloud store's main context, never a `@Query` against the
/// mirror.
///
/// CloudKit constraints honoured: every stored property is optional or
/// defaulted, there is no `@Attribute(.unique)`, no relationship and no
/// `#Index`. Uniqueness can't be enforced by CloudKit — the reconciler dedupes
/// by `serverID` (falling back to `id` for a row without one). The token rides the private database end-to-end encrypted.
@Model
final class SyncedRecordingServer {
    var id: UUID = UUID()
    /// Raw `RecordingServerKind`. Kept raw so a row written by a newer build
    /// with an unknown backend survives untouched instead of being coerced.
    var kindRaw: String = RecordingServerKind.lumeRecorder.rawValue
    var name: String = ""
    var baseURL: String = ""
    /// The server's own identity, as reported by its info endpoint.
    var serverID: UUID?
    /// The device identity the server issued at pairing; needed to unpair.
    var deviceID: UUID?
    @Attribute(.allowsCloudEncryption) var token: String = ""
    var isEnabled: Bool = true
    /// Last time this record changed. Dedupe tie-break only.
    var updatedAt: Date = Date()

    /// `nil` for a backend this build does not support.
    var kind: RecordingServerKind? {
        RecordingServerKind(rawValue: kindRaw)
    }

    init(
        id: UUID = UUID(),
        kind: RecordingServerKind = .lumeRecorder,
        name: String,
        baseURL: String,
        serverID: UUID? = nil,
        deviceID: UUID? = nil,
        token: String = "",
        isEnabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        kindRaw = kind.rawValue
        self.name = name
        self.baseURL = baseURL
        self.serverID = serverID
        self.deviceID = deviceID
        self.token = token
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}
