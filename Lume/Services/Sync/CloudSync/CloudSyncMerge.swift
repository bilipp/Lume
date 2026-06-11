import Foundation

// The pure, side-effect-free heart of iCloud sync: a three-way merge over a
// *shadow baseline*. Keeping it free of SwiftData / CloudKit lets it be unit
// tested exhaustively and reasoned about in isolation — the engine
// (`CloudSyncEngine`) only translates its verdicts into store mutations.
//
// Three-way merge means each side is compared not against the other but against
// the value we last saw agreed (`shadow`). That single idea handles create,
// update, *and* delete in both directions, because "absent" is just `nil`:
//
//   • local changed, cloud didn't            → push local (incl. local == nil ⇒ delete cloud)
//   • cloud changed, local didn't            → pull cloud (incl. cloud == nil ⇒ delete local)
//   • both changed the same way              → nothing to do, just re-baseline
//   • both changed differently (a conflict)  → field-level merge per the policy
//
// Without the shadow you cannot tell an edit from a delete (both look like
// "different from the other side"), which is what makes naive two-way mirrors
// resurrect deleted rows.

/// The outcome of reconciling one id across the two stores.
nonisolated enum MergeVerdict<Value: Equatable>: Equatable {
    /// Nothing differs from the shadow — leave both stores and the shadow alone.
    case noChange
    /// Write `Value?` to the cloud mirror (nil ⇒ delete the mirror) and adopt it
    /// as the new shadow.
    case pushToCloud(Value?)
    /// Write `Value?` to the local model (nil ⇒ delete locally) and adopt it as
    /// the new shadow.
    case pullToLocal(Value?)
    /// A genuine conflict was merged: write the merged value to *both* stores and
    /// adopt it as the new shadow. Always carries a concrete value (a merge of
    /// two deletions is just a deletion, surfaced as `pushToCloud(nil)`).
    case writeBoth(Value)
}

nonisolated enum CloudSyncMerge {
    /// Three-way merge for a single id.
    ///
    /// - Parameters:
    ///   - local: the current local value, or nil if absent locally.
    ///   - cloud: the current cloud-mirror value, or nil if absent in the cloud.
    ///   - shadow: the value both sides last agreed on, or nil if this id has
    ///     never synced.
    ///   - mergeConflict: invoked only when both sides changed *and* both are
    ///     non-nil, to combine them field-by-field per the value's policy.
    static func reconcile<Value: Equatable>(
        local: Value?,
        cloud: Value?,
        shadow: Value?,
        mergeConflict: (_ local: Value, _ cloud: Value) -> Value
    ) -> MergeVerdict<Value> {
        let localChanged = local != shadow
        let cloudChanged = cloud != shadow

        switch (localChanged, cloudChanged) {
        case (false, false):
            return .noChange
        case (true, false):
            // Only the local side moved (an edit, or a delete when local == nil).
            return .pushToCloud(local)
        case (false, true):
            // Only the cloud side moved.
            return .pullToLocal(cloud)
        case (true, true):
            // Both moved. If they happened to land on the same value there is
            // nothing to write, only a shadow re-baseline — express that as a
            // push (cheap and idempotent).
            if local == cloud {
                return .pushToCloud(local)
            }
            switch (local, cloud) {
            case let (local?, cloud?):
                return .writeBoth(mergeConflict(local, cloud))
            case let (local?, nil):
                // One side deleted, the other edited. Preserve the edit (an
                // un-delete) — losing a user's still-present data is the worse
                // failure. Re-create on the side that deleted.
                return .writeBoth(local)
            case let (nil, cloud?):
                return .writeBoth(cloud)
            case (nil, nil):
                return .noChange
            }
        }
    }
}

// MARK: - Playlist config

/// The syncable fields of a `Playlist`. Conflicts resolve last-write-wins
/// favouring the cloud (see `mergeConflict`), since playlist config is shared
/// truth that rarely changes on two devices at once.
nonisolated struct PlaylistConfigValues: Codable, Equatable {
    var name: String
    var serverURL: String
    var username: String
    var password: String
    var sourceTypeRaw: String
    var epgURL: String?
    var syncEnabled: Bool

    /// Conflict policy: cloud wins. Deterministic and adequate for config.
    static func mergeConflict(local _: PlaylistConfigValues, cloud: PlaylistConfigValues) -> PlaylistConfigValues {
        cloud
    }
}

// MARK: - Per-content user state

/// The syncable user state of a single catalog item. Fields irrelevant to a
/// given kind stay at their defaults and round-trip harmlessly (a `Series` never
/// sets `watchProgress`, a `LiveStream` never sets `addedToWatchlistDate`).
nonisolated struct ContentStateValues: Codable, Equatable {
    var watchProgress: Double
    var isWatched: Bool
    var lastWatchedDate: Date?
    var isFavorite: Bool
    var addedToWatchlistDate: Date?
    var favoriteOrder: Int?

    /// Whether every field is at its default — such an item carries no user
    /// state and is represented as *absent* (nil) so it never gets a cloud
    /// record and a cleared item deletes its record.
    var isEmpty: Bool {
        watchProgress == 0 && !isWatched && lastWatchedDate == nil
            && !isFavorite && addedToWatchlistDate == nil && favoriteOrder == nil
    }

    /// Conflict policy (both devices changed this item since the last sync):
    /// keep the most-progressed, most-complete, still-favorited union. Chosen so
    /// a conflict can never *lose* progress or a favorite — the failure mode
    /// users notice. Pure last-write-wins is available by swapping this out.
    static func mergeConflict(local: ContentStateValues, cloud: ContentStateValues) -> ContentStateValues {
        ContentStateValues(
            watchProgress: max(local.watchProgress, cloud.watchProgress),
            isWatched: local.isWatched || cloud.isWatched,
            lastWatchedDate: laterDate(local.lastWatchedDate, cloud.lastWatchedDate),
            isFavorite: local.isFavorite || cloud.isFavorite,
            // Keep the earliest "added" stamp so a re-favorite on one device
            // doesn't reset the position of an older watchlist entry.
            addedToWatchlistDate: earlierDate(local.addedToWatchlistDate, cloud.addedToWatchlistDate),
            favoriteOrder: local.favoriteOrder ?? cloud.favoriteOrder
        )
    }

    private static func laterDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        default: lhs ?? rhs
        }
    }

    private static func earlierDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        default: lhs ?? rhs
        }
    }
}
