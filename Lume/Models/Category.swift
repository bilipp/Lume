import Foundation
import SwiftData

enum CategoryType: String, Codable {
    case live
    case vod
    case series
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
    var sortOrder: Int = 0
    var customIcon: String?
    var lastRefreshed: Date?

    init(apiId: String, name: String, parentId: Int, typeRaw: String, playlist: Playlist? = nil) {
        self.id = "\(playlist?.id.uuidString ?? "unknown")-\(typeRaw)-\(apiId)"
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
