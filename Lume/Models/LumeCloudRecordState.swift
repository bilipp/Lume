import Foundation
import SwiftData

/// The Lume Cloud transport's bookkeeping for one server record
/// (PROTOCOL.md §6.1). Local-only: it lives in `LumeCloudUserData.store`
/// beside the mirror models and is never synced anywhere.
@Model
final class LumeCloudRecordState {
    #Index<LumeCloudRecordState>([\.logicalKey], [\.isDirty])

    /// The server record id, derived from `logicalKey` and the account's keys.
    @Attribute(.unique) var rid: String = ""
    /// The protocol's logical key for the record (PROTOCOL.md §3).
    var logicalKey: String = ""
    /// The protocol's record type (PROTOCOL.md §3).
    var type: String = ""
    /// The server version this device last saw; 0 for a record never pushed.
    var version: Int = 0
    /// The canonical `LumeCloudPayload.encoded()` bytes last synced — the base of
    /// the 3-way merge. Carries fields and types this build doesn't know, so a
    /// push writes them back unchanged. Nil until the record first syncs.
    var lastSyncedPayload: Data?
    /// Whether the local value differs from `lastSyncedPayload` and awaits a push.
    var isDirty: Bool = false
    /// The user deleted the record: the next push sends a tombstone. Set only
    /// through `LumeCloudTransport.recordDeletion(logicalKey:)` — a row missing
    /// from the mirror is never read as a deletion on its own.
    var isDeletionPending: Bool = false
    /// The envelope, exactly as pulled (base64url), of a server version this
    /// build can't apply: an unknown envelope version, a payload that doesn't
    /// decode, a `rid` its logical key doesn't derive, or a type this build
    /// doesn't know (PROTOCOL.md §2.4, §2.5). That version is retried on every
    /// pull, and a push never writes over or deletes the record while it is
    /// held. `version` and `lastSyncedPayload` stay at the last version applied.
    var undecodableCiphertext: String?
    var undecodableVersion: Int = 0
    var undecodableSeq: Int = 0

    init(
        rid: String,
        logicalKey: String,
        type: String,
        version: Int = 0,
        lastSyncedPayload: Data? = nil,
        isDirty: Bool = false
    ) {
        self.rid = rid
        self.logicalKey = logicalKey
        self.type = type
        self.version = version
        self.lastSyncedPayload = lastSyncedPayload
        self.isDirty = isDirty
    }
}

nonisolated extension LumeCloudRecordState {
    /// The server holds a version of this record this build can't apply.
    var isUndecodable: Bool {
        undecodableCiphertext != nil
    }
}
