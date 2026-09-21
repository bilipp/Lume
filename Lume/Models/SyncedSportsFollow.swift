import Foundation
import SwiftData

/// CloudKit-synced mirror of one followed sports league or team, scoped to a
/// profile and ordered.
///
/// There is no local SwiftData counterpart: the sports hub reads followed
/// leagues/teams through `SportsFollowService` directly over the cloud store's
/// main context — never a `@Query` against the mirror. This record exists purely
/// so a follow added on one device reaches the others, and a fresh device pulls
/// them in.
///
/// `key` is provider-prefixed and identifies the followed thing across devices:
/// `"espn:soccer/ger.1"` for a league, `"espn:soccer/ger.1:132"` for a team.
/// `kindRaw` is `"league"` or `"team"`. Follows are per-profile (`profileID`) and
/// ordered (`sortOrder`) — the first few lead the Home shelf.
///
/// CloudKit constraints honoured: every stored property is optional or defaulted,
/// there is no `@Attribute(.unique)`, and there are no relationships. Uniqueness
/// (one row per `key` + `profileID`) can't be enforced by CloudKit — the
/// reconciler dedupes by that pair itself.
@Model
final class SyncedSportsFollow {
    #Index<SyncedSportsFollow>([\.profileID])

    /// Provider-prefixed identifier of the followed league or team.
    var key: String = ""
    /// `"league"` or `"team"`.
    var kindRaw: String = "team"
    /// The profile this follow belongs to. `nil` is treated as the default
    /// profile until bootstrap claims it, mirroring `UserContentState`.
    var profileID: UUID?
    /// Position in the profile's ordered follow list.
    var sortOrder: Int = 0
    /// Last time this record changed. Dedupe tie-break only; correctness does not
    /// rest on this clock.
    var updatedAt: Date = Date()

    init(key: String, kindRaw: String = "team", profileID: UUID?, sortOrder: Int = 0, updatedAt: Date = Date()) {
        self.key = key
        self.kindRaw = kindRaw
        self.profileID = profileID
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }
}
