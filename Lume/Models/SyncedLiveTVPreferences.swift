import Foundation
import SwiftData

/// CloudKit-synced mirror of the Live TV rail preferences — whether Favorites
/// and Recently Watched are offered above the categories.
///
/// `UserDefaults` (`LiveTVRailSettings`) stays the local store of record, which
/// is what the rails read through `@AppStorage`; this record is only the
/// transport between devices, reconciled by `CloudSyncEngine+Preferences`.
///
/// Account-wide rather than profile-scoped, like `SyncedParentalPIN`: the
/// choice describes how the Live TV tab looks on every profile.
///
/// A singleton in practice — `id` is always `Self.singletonID`. CloudKit cannot
/// enforce uniqueness, so two devices can each insert one before they converge;
/// the reconciler dedupes on `updatedAt`.
///
/// CloudKit constraints honoured: every stored property is defaulted, there is
/// no `@Attribute(.unique)`, and there are no relationships.
@Model
final class SyncedLiveTVPreferences {
    static let singletonID = "live-tv-preferences"

    var id: String = SyncedLiveTVPreferences.singletonID
    var showsFavorites: Bool = LiveTVRailSettings.showsFavoritesDefault
    var showsRecentlyWatched: Bool = LiveTVRailSettings.showsRecentlyWatchedDefault
    /// Last time this record changed. Dedupe tie-break only.
    var updatedAt: Date = Date()

    init(showsFavorites: Bool, showsRecentlyWatched: Bool, updatedAt: Date = Date()) {
        self.showsFavorites = showsFavorites
        self.showsRecentlyWatched = showsRecentlyWatched
        self.updatedAt = updatedAt
    }
}
