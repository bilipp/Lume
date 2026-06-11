import Foundation
import SwiftData

@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String
    /// Xtream: the portal base URL. M3U: the playlist URL (http(s) or a local
    /// `file://` URL produced by the file importer).
    var serverURL: String
    var username: String
    var password: String

    /// Where this playlist's content comes from. Stored as a raw string so the
    /// attribute stays lightweight-migration safe; existing rows default to
    /// Xtream. Access through `sourceType`.
    var sourceTypeRaw: String = PlaylistSourceType.xtream.rawValue
    /// XMLTV guide URL for m3u playlists. Filled from the form or, when left
    /// empty, from the playlist's own `url-tvg` header on first sync.
    var epgURL: String?

    var serverTimezone: String?
    var serverVersion: String?

    var userStatus: String?
    var maxConnections: String?
    var activeConnections: String?
    var expDate: String?

    var syncEnabled: Bool = true
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

    /// Creates an m3u playlist. Username/password stay empty — m3u sources
    /// carry any credentials inside the URL itself.
    convenience init(name: String, m3uURL: String, epgURL: String? = nil) {
        self.init(name: name, serverURL: m3uURL, username: "", password: "")
        sourceTypeRaw = PlaylistSourceType.m3u.rawValue
        self.epgURL = (epgURL?.isEmpty == false) ? epgURL : nil
    }
}

enum PlaylistSourceType: String, Codable {
    case xtream
    case m3u
}

enum SyncStatus: String, Codable {
    case idle
    case syncing
    case error
}

extension Playlist {
    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .idle }
        set { syncStatusRaw = newValue.rawValue }
    }

    var sourceType: PlaylistSourceType {
        get { PlaylistSourceType(rawValue: sourceTypeRaw) ?? .xtream }
        set { sourceTypeRaw = newValue.rawValue }
    }
}
