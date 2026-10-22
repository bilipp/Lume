import Foundation
import SwiftData

/// CloudKit-synced record of which sync backend this Apple ID's devices use.
///
/// Lives only in the iCloud `CloudUserData` store: it is how a fresh Apple
/// device learns that the account moved to Lume Cloud, and how Leave / Delete
/// send every Apple device back to iCloud. "Off" is per device and is never
/// written here.
///
/// A device acts on the record only when `serverURL` equals its own
/// `LumeCloudConfig.serverURL`, so staging and production accounts never mix.
/// Never bound to a `@Query`, and never touched in SIDE_LOAD builds (no
/// CloudKit there).
///
/// A singleton in practice — `id` is always `Self.singletonID`. CloudKit cannot
/// enforce uniqueness, so two devices can each insert one before they converge;
/// readers dedupe on `changedAt`.
///
/// CloudKit constraints honoured: every stored property is optional or defaulted,
/// there is no `@Attribute(.unique)`, and there are no relationships.
/// `CD_SyncedBackendChoice` must be deployed to CloudKit Production before release.
@Model
final class SyncedBackendChoice {
    static let singletonID = "backend-choice"

    /// The stored values of `backend`.
    nonisolated enum Backend: String {
        case icloud
        case lumecloud
    }

    var id: String = SyncedBackendChoice.singletonID
    /// A `Backend` raw value. Kept as a string so a value a newer build writes
    /// survives a round trip through an older one.
    var backend: String = Backend.icloud.rawValue
    /// The Lume Cloud server the account lives on. An `icloud` record names
    /// the server of the account that was left (empty when unknown).
    var serverURL: String = ""
    /// The Lume Cloud account id. An `icloud` record names the account that
    /// was left, so only that account's devices follow (empty when unknown).
    var accountId: String = ""
    /// The account's 32-byte root key. The synchronizable Keychain item is the
    /// primary copy; when the two disagree, this record wins.
    @Attribute(.allowsCloudEncryption) var rootKey: Data?
    /// Last time the choice changed. Dedupes duplicate singletons.
    var changedAt: Date = Date()

    init(
        backend: Backend,
        serverURL: String = "",
        accountId: String = "",
        rootKey: Data? = nil,
        changedAt: Date = Date()
    ) {
        self.backend = backend.rawValue
        self.serverURL = serverURL
        self.accountId = accountId
        self.rootKey = rootKey
        self.changedAt = changedAt
    }
}
