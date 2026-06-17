import Foundation
import SwiftData

/// The kind of catalog item a `UserContentState` record applies to. Stored on
/// the record so the reconciler can route a synced state back to the right local
/// model without re-parsing the id string.
enum SyncedContentKind: String, Codable, CaseIterable {
    case movie
    case series
    case episode
    case live
}

/// CloudKit-synced per-content user state — the parts of the catalog the user
/// actually creates: watch progress, watched flag, favorites and watchlist.
///
/// Keyed by `contentId`, which equals the local model's `id` (`Movie.id`,
/// `Series.id`, `Episode.id`, `LiveStream.id`). Those ids embed the playlist
/// UUID, so a record produced on one device addresses the same catalog item on
/// every other device once that device has synced the playlist's catalog.
///
/// Only items with *some* non-default state ever get a record — the reconciler
/// skips untouched catalog rows entirely, keeping the synced set small.
///
/// CloudKit constraints honoured: all stored properties optional or defaulted,
/// no `@Attribute(.unique)`, no relationships.
@Model
final class UserContentState {
    // The reconciler and every profile operation fetch mirrors scoped to one
    // `profileID`; index it so SQLite finds the active profile's rows without
    // scanning every profile's records. Local-only fetch index — it doesn't
    // alter the CloudKit record schema.
    #Index<UserContentState>([\.profileID])

    var contentId: String = ""
    var kindRaw: String = SyncedContentKind.movie.rawValue

    /// The profile this state belongs to (`UserProfile.id`). Optional for
    /// backwards compatibility: records written before profiles existed load
    /// with `nil` and are claimed by the default profile during bootstrap (see
    /// `CloudSyncEngine.bootstrapProfiles`). New records are always stamped.
    var profileID: UUID?

    var watchProgress: Double = 0
    var isWatched: Bool = false
    var lastWatchedDate: Date?

    var isFavorite: Bool = false
    var addedToWatchlistDate: Date?
    /// Live-stream Favorites ordering (`LiveStream.favoriteOrder`). Nil for other
    /// kinds.
    var favoriteOrder: Int?

    /// The user's "For You" vote (`0` none, `1` up, `-1` down). Defaulted for
    /// CloudKit and additive, so records written before recommendations existed
    /// load as unvoted. Only movies and series ever set it.
    var recommendationVoteRaw: Int = 0

    var updatedAt: Date = Date()

    var kind: SyncedContentKind {
        get { SyncedContentKind(rawValue: kindRaw) ?? .movie }
        set { kindRaw = newValue.rawValue }
    }

    init(
        contentId: String,
        kind: SyncedContentKind,
        profileID: UUID? = nil,
        watchProgress: Double = 0,
        isWatched: Bool = false,
        lastWatchedDate: Date? = nil,
        isFavorite: Bool = false,
        addedToWatchlistDate: Date? = nil,
        favoriteOrder: Int? = nil,
        recommendationVoteRaw: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.contentId = contentId
        kindRaw = kind.rawValue
        self.profileID = profileID
        self.watchProgress = watchProgress
        self.isWatched = isWatched
        self.lastWatchedDate = lastWatchedDate
        self.isFavorite = isFavorite
        self.addedToWatchlistDate = addedToWatchlistDate
        self.favoriteOrder = favoriteOrder
        self.recommendationVoteRaw = recommendationVoteRaw
        self.updatedAt = updatedAt
    }
}
