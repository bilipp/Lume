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
    @Attribute(.unique) var id: String
    var apiId: String
    var name: String
    var parentId: Int
    var typeRaw: String
    var playlist: Playlist?

    var isHidden: Bool = false
    /// The playlist's own order, refreshed from the provider on every sync.
    var sortOrder: Int = 0
    /// A user-defined order set in Content Management. `nil` means "follow the
    /// playlist order"; once the user reorders, every category in the group gets
    /// a dense value so it survives re-syncs (which only touch `sortOrder`).
    var customOrder: Int?
    var customIcon: String?
    var lastRefreshed: Date?

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
}
