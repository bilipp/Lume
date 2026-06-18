import Foundation
import SwiftData

/// The kind of football entity a user has marked as a favorite for the Upcoming
/// Matches row. Football-only for now; the raw values are stable storage keys.
nonisolated enum SportFavoriteKind: String, Codable, CaseIterable {
    case league
    case team
}

/// A league/cup or team the user wants to follow. Drives which fixtures the
/// Upcoming Matches row fetches (see `SportAnnouncementsService`).
///
/// Lives in the **local catalog** store, not the CloudKit mirror: it's a small
/// preference list (like the Home layout order) and keeping it out of the cloud
/// schema avoids touching the delicate user-data reconciler. It does not sync
/// across devices yet.
@Model
final class SportFavorite {
    /// `"<kind>-<externalID>"`, so the same league/team can't be added twice.
    @Attribute(.unique) var id: String
    var kindRaw: String
    /// TheSportsDB id of the league or team this favorite points at.
    var externalID: String
    var name: String
    /// Badge / logo artwork URL, when the provider supplied one.
    var badgeURL: String?
    var addedAt: Date

    var kind: SportFavoriteKind {
        SportFavoriteKind(rawValue: kindRaw) ?? .league
    }

    init(kind: SportFavoriteKind, externalID: String, name: String, badgeURL: String? = nil) {
        id = "\(kind.rawValue)-\(externalID)"
        kindRaw = kind.rawValue
        self.externalID = externalID
        self.name = name
        self.badgeURL = badgeURL
        addedAt = Date()
    }
}
