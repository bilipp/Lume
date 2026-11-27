import Foundation
import SwiftData

/// Stored declarations frozen before the two local identity columns.
/// A mutated Schema cannot seed current @Model instances with different metadata.
enum StalkerLegacySchema {
    @Model
    final class Playlist {
        var id: UUID = UUID()
        var name: String
        var serverURL: String
        var username: String
        var password: String
        var sourceTypeRaw: String = "xtream"
        var epgURL: String?
        var streamFormatRaw: String = "automatic"
        var macAddress: String?
        var jellyfinAccessToken: String?
        var jellyfinUserId: String?
        var plexAccessToken: String?
        var resolvesSourcesOnDemand: Bool?
        var serverTimezone: String?
        var serverVersion: String?
        var userStatus: String?
        var maxConnections: String?
        var activeConnections: String?
        var expDate: String?
        var allowedOutputFormatsRaw: String?
        var syncEnabled: Bool = true
        var hiddenTabsRaw: String = ""
        var combinedTypesRaw: String = ""
        var combinedPriority: Int?
        var lastSyncDate: Date?
        var syncStatusRaw: String = "idle"
        @Relationship(deleteRule: .cascade) var categories: [Category] = []
        var addedAt: Date = Date()
        var lastUpdated: Date?

        init(name: String, serverURL: String, username: String, password: String) {
            self.name = name
            self.serverURL = serverURL
            self.username = username
            self.password = password
        }
    }

    @Model
    final class Category {
        #Index<Category>([\.isRestricted], [\.isHidden], [\.customOrder])
        @Attribute(.unique) var id: String
        var apiId: String
        var name: String
        var parentId: Int
        var typeRaw: String
        var playlist: Playlist?
        var isHidden: Bool = false
        var isRestricted: Bool = false
        var sortOrder: Int = 0
        var customOrder: Int?
        var customIcon: String?
        var lastRefreshed: Date?
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
}
