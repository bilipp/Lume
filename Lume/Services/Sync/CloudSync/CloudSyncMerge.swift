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
    var macAddress: String
    var sourceTypeRaw: String
    var epgURL: String?
    var syncEnabled: Bool

    init(
        name: String,
        serverURL: String,
        username: String,
        password: String,
        macAddress: String = "",
        sourceTypeRaw: String,
        epgURL: String?,
        syncEnabled: Bool
    ) {
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.macAddress = macAddress
        self.sourceTypeRaw = sourceTypeRaw
        self.epgURL = epgURL
        self.syncEnabled = syncEnabled
    }

    /// Hand-rolled decode so a shadow baseline persisted before Stalker support
    /// (no `macAddress` key) still decodes — the field falls back to "" rather
    /// than failing the whole baseline, which would discard the shadow and risk
    /// a spurious mass reconcile.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        sourceTypeRaw = try container.decode(String.self, forKey: .sourceTypeRaw)
        epgURL = try container.decodeIfPresent(String.self, forKey: .epgURL)
        syncEnabled = try container.decode(Bool.self, forKey: .syncEnabled)
    }

    /// Conflict policy: cloud wins. Deterministic and adequate for config.
    static func mergeConflict(local _: PlaylistConfigValues, cloud: PlaylistConfigValues) -> PlaylistConfigValues {
        cloud
    }
}

// MARK: - Manual EPG source

/// The syncable fields of a *manual* `EPGSource`. Conflicts resolve cloud-wins,
/// like playlist config — EPG sources are shared truth that rarely change on two
/// devices at once.
nonisolated struct EPGSourceValues: Codable, Equatable {
    var name: String
    var url: String
    var isEnabled: Bool

    static func mergeConflict(local _: EPGSourceValues, cloud: EPGSourceValues) -> EPGSourceValues {
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
    /// "For You" vote (`0` none, `1` up, `-1` down). Defaulted so the many
    /// call sites that don't carry a vote (episodes, live, older code) stay
    /// unchanged.
    var recommendationVoteRaw: Int = 0
    /// Content Management visibility — categories and live channels. Defaulted so
    /// call sites for kinds that can't be hidden (movie/series/episode) stay
    /// unchanged.
    var isHidden: Bool = false
    /// Content Management ordering for *categories* only. Per-channel
    /// within-category order is intentionally device-local (it would write one
    /// record per channel), so live entries always leave this nil.
    var customOrder: Int?

    /// Whether every field is at its default — such an item carries no user
    /// state and is represented as *absent* (nil) so it never gets a cloud
    /// record and a cleared item deletes its record.
    var isEmpty: Bool {
        watchProgress == 0 && !isWatched && lastWatchedDate == nil
            && !isFavorite && addedToWatchlistDate == nil && favoriteOrder == nil
            && recommendationVoteRaw == 0
            && !isHidden && customOrder == nil
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
            favoriteOrder: local.favoriteOrder ?? cloud.favoriteOrder,
            recommendationVoteRaw: mergeVote(local.recommendationVoteRaw, cloud.recommendationVoteRaw),
            // Union, matching the never-lose-a-favorite policy: if either device
            // hid the item, keep it hidden. A genuine toggle conflict between two
            // devices in one sync window is the only case this can't resolve
            // perfectly, and it's vanishingly rare for a hide/show toggle.
            isHidden: local.isHidden || cloud.isHidden,
            // Prefer a concrete order; only one device realistically reorders a
            // given group between syncs, so a non-nil value is the intended one.
            customOrder: local.customOrder ?? cloud.customOrder
        )
    }

    /// Vote conflict policy: an explicit vote beats none, and a genuine up/down
    /// clash resolves to "not interested" (`-1`) — once a user rejects a title
    /// on any device, keep it out of recommendations.
    private static func mergeVote(_ lhs: Int, _ rhs: Int) -> Int {
        if lhs == rhs { return lhs }
        if lhs == 0 { return rhs }
        if rhs == 0 { return lhs }
        return min(lhs, rhs)
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

extension ContentStateValues {
    enum CodingKeys: String, CodingKey {
        case watchProgress, isWatched, lastWatchedDate, isFavorite
        case addedToWatchlistDate, favoriteOrder, recommendationVoteRaw
        case isHidden, customOrder
    }

    /// Hand-rolled decode so a shadow baseline persisted before a field existed
    /// (no `recommendationVoteRaw` / `isHidden` / `customOrder` key) still
    /// decodes — the field falls back to its default instead of failing the whole
    /// baseline and forcing a re-merge. The synthesized decode would treat the
    /// missing key as an error.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchProgress = try container.decode(Double.self, forKey: .watchProgress)
        isWatched = try container.decode(Bool.self, forKey: .isWatched)
        lastWatchedDate = try container.decodeIfPresent(Date.self, forKey: .lastWatchedDate)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        addedToWatchlistDate = try container.decodeIfPresent(Date.self, forKey: .addedToWatchlistDate)
        favoriteOrder = try container.decodeIfPresent(Int.self, forKey: .favoriteOrder)
        recommendationVoteRaw = try container.decodeIfPresent(Int.self, forKey: .recommendationVoteRaw) ?? 0
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        customOrder = try container.decodeIfPresent(Int.self, forKey: .customOrder)
    }
}
