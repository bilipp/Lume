import Foundation
import SwiftData

/// CloudKit-synced mirror of the parental-control PIN.
///
/// The PIN itself is never stored — only the salted SHA-256 hash that
/// `ParentalControlsStore` keeps in the keychain. The keychain remains the local
/// store of record (it is what `verify` reads); this record exists purely as the
/// *transport* between devices, because iCloud Keychain does not sync to tvOS —
/// and tvOS is precisely where an unenforced parental gate matters most.
///
/// Deliberately **not** profile-scoped, unlike `UserContentState`: the PIN is the
/// thing a child uses to escape their profile, so scoping it to a profile would
/// make it unenforceable exactly when it is needed.
///
/// A singleton in practice — `id` is always `Self.singletonID`. CloudKit cannot
/// enforce uniqueness, so two devices can each insert one before they converge;
/// the reconciler dedupes on `updatedAt`.
///
/// ## Security note
///
/// CloudKit's private database is encrypted in transit and at rest but is not
/// end-to-end encrypted the way iCloud Keychain is. That is a real downgrade in
/// protection for this hash — though a modest one in practice: a four-digit PIN
/// drawn from 10,000 candidates, salted with a constant that ships in the binary,
/// falls to brute force the moment anyone holds the hash, wherever it is stored.
/// The PIN is a parental speed bump, not a secret, and is treated as one here.
///
/// CloudKit constraints honoured: every stored property is optional or defaulted,
/// there is no `@Attribute(.unique)`, and there are no relationships.
@Model
final class SyncedParentalPIN {
    /// The only id this record ever uses. A fixed string rather than a UUID so
    /// every device addresses the same row without having to agree on one first.
    static let singletonID = "parental-pin"

    var id: String = SyncedParentalPIN.singletonID
    /// Salted SHA-256 hash of the PIN, in the exact form `ParentalControlsStore`
    /// stores in the keychain. Never the PIN.
    var pinHash: String = ""
    /// Last time this record's hash changed. Used only to dedupe duplicate
    /// singletons; correctness rests on the shadow baseline, not this clock.
    var updatedAt: Date = Date()

    /// `id` is left to its default — the singleton id is the only value it ever
    /// takes, and assigning it here again just says the same thing twice.
    init(pinHash: String, updatedAt: Date = Date()) {
        self.pinHash = pinHash
        self.updatedAt = updatedAt
    }
}

/// CloudKit-synced mirror of a category's parental restriction
/// (`Category.isRestricted`) — the "locked" toggle in Content Management.
///
/// Like `SyncedParentalPIN` and unlike `UserContentState`, this is **not**
/// profile-scoped. A restriction is a rule a parent sets *about* a child profile,
/// not a preference belonging to whichever profile happened to be active when it
/// was set. Riding the per-profile channel would file it under the parent's
/// profile and then never re-apply it while the child's profile was active —
/// which is the bug this record exists to prevent.
///
/// Only restricted categories get a record. An unrestricted category has no row
/// at all, so a playlist the user never locked anything in costs nothing; the
/// reconciler reads presence itself as the restriction.
///
/// `categoryID` matches `Category.id` verbatim, which embeds the playlist UUID,
/// so a record written on one device addresses the same category on every other
/// device once that playlist's catalog has synced.
@Model
final class SyncedCategoryRestriction {
    /// Mirrors `Category.id`. Not unique (CloudKit can't enforce it) — the
    /// reconciler dedupes by this value itself.
    var categoryID: String = ""
    /// Always `true` in practice; the row's *existence* is the restriction, and
    /// lifting it deletes the row. Stored anyway so a record is self-describing
    /// in the CloudKit console and so the field is there if restrictions ever
    /// gain a third state.
    var isRestricted: Bool = true
    /// Last time this record changed. Dedupe tie-break only.
    var updatedAt: Date = Date()

    init(categoryID: String, isRestricted: Bool = true, updatedAt: Date = Date()) {
        self.categoryID = categoryID
        self.isRestricted = isRestricted
        self.updatedAt = updatedAt
    }
}
