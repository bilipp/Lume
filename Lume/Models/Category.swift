import Foundation
import SwiftData
import SwiftUI

enum CategoryType: String, Codable, CaseIterable, Identifiable {
    case live
    case vod
    case series

    var id: String {
        rawValue
    }

    /// User-facing label, matching the tab names.
    var label: String {
        switch self {
        case .live: "Live TV"
        case .vod: "Movies"
        case .series: "Series"
        }
    }

    /// Localized variant of `label` for rendering in SwiftUI `Text`. `label`
    /// itself stays a plain `String` because it is also interpolated into
    /// composed strings elsewhere.
    var localizedLabel: LocalizedStringKey {
        LocalizedStringKey(label)
    }
}

@Model
final class Category {
    // `MainTabView` queries restricted categories on every Category-table change
    // (i.e. every sync) to build the child-profile restriction set; index
    // `isRestricted` so that query seeks instead of scanning all categories.
    // The iCloud reconciler exports customized categories (`isHidden ||
    // customOrder != nil`) on every pass; index both so it seeks the handful
    // of customized rows (SQLite's OR optimization needs each disjunct
    // independently indexed).
    #Index<Category>([\.isRestricted], [\.isHidden], [\.customOrder])

    @Attribute(.unique) var id: String
    var apiId: String
    var name: String
    var parentId: Int
    var typeRaw: String
    var playlist: Playlist?

    var isHidden: Bool = false
    /// Restricted from child profiles: while a child profile is active this
    /// category, and every title in it, is hidden from browsing and search.
    /// Toggling it is gated behind the parental-control PIN.
    var isRestricted: Bool = false
    /// The playlist's own order, refreshed from the provider on every sync.
    var sortOrder: Int = 0
    /// A user-defined order set in Content Management. `nil` means "follow the
    /// playlist order"; once the user reorders, every category in the group gets
    /// a dense value so it survives re-syncs (which only touch `sortOrder`).
    var customOrder: Int?
    var customIcon: String?
    var lastRefreshed: Date?
    /// When this category's full content was last imported from the portal on
    /// demand. Stalker playlists don't sync their whole catalog (the portal
    /// serves ~14 items per request); a default sync only seeds the newest
    /// titles, so a category is otherwise near-empty until opened. `nil` means
    /// never imported — opening the category blocks on a first fetch; once the
    /// stamp outlives `stalkerContentTTL`, opening it revalidates in the
    /// background instead. Unused by Xtream/m3u, whose categories are fully
    /// synced up front.
    var contentImportedAt: Date?

    init(apiId: String, name: String, parentId: Int, typeRaw: String, playlist: Playlist? = nil) {
        id = "\(playlist?.id.uuidString ?? "unknown")-\(typeRaw)-\(apiId)"
        self.apiId = apiId
        self.name = name
        self.parentId = parentId
        self.typeRaw = typeRaw
        self.playlist = playlist
    }
}

extension Category {
    var type: CategoryType {
        get { CategoryType(rawValue: typeRaw) ?? .live }
        set { typeRaw = newValue.rawValue }
    }

    convenience init(apiId: String, name: String, parentId: Int, type: CategoryType, playlist: Playlist? = nil) {
        self.init(apiId: apiId, name: name, parentId: parentId, typeRaw: type.rawValue, playlist: playlist)
    }

    /// How long an on-demand Stalker category import stays fresh. Past this,
    /// opening the category revalidates it against the portal in the background
    /// (see `MovieCategoryView` / `SeriesCategoryView`) so provider-added titles
    /// surface without a manual refresh — the only refresh path tvOS has.
    static let stalkerContentTTL: TimeInterval = 24 * 60 * 60

    /// Whether the last on-demand import is old enough to revalidate. `true`
    /// when the category was never imported at all.
    var stalkerContentStale: Bool {
        guard let contentImportedAt else { return true }
        return Date().timeIntervalSince(contentImportedAt) > Self.stalkerContentTTL
    }
}
