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

    /// Container the live streams of this playlist are requested in. Stored as a
    /// raw string so the attribute stays lightweight-migration safe; existing
    /// rows default to `automatic`, which keeps whatever the provider hands out
    /// (HLS for Xtream, the playlist's own URL for m3u). Deliberately *not*
    /// mirrored to CloudKit — which container a network and decoder cope with is
    /// a per-device trait, like the per-channel `customOrder`. Access through
    /// `streamFormat`.
    var streamFormatRaw: String = PlaylistStreamFormat.automatic.rawValue

    /// Stalker portals authenticate by MAC address rather than credentials.
    /// `serverURL` holds the portal URL; this holds the bound MAC (e.g.
    /// `00:1A:79:xx:xx:xx`). `nil` for Xtream / m3u sources.
    var macAddress: String?

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

    /// Creates a Stalker portal playlist. The portal URL goes in `serverURL` and
    /// the bound MAC in `macAddress`; username/password are optional (only some
    /// portals require them).
    convenience init(name: String, portalURL: String, macAddress: String, username: String = "", password: String = "") {
        self.init(name: name, serverURL: portalURL, username: username, password: password)
        sourceTypeRaw = PlaylistSourceType.stalker.rawValue
        self.macAddress = macAddress
    }
}

enum PlaylistSourceType: String, Codable {
    case xtream
    case m3u
    case stalker
}

/// The container a playlist's live streams are requested in.
///
/// `automatic` is the historical behaviour and stays the default: Xtream builds
/// HLS URLs, and m3u channels play at exactly the URL the playlist listed. The
/// two explicit choices exist because providers serve the same channel through
/// both endpoints and only one of them tends to work well on a given network or
/// decoder — HLS survives lossy connections, MPEG-TS starts faster and avoids
/// the repackaging some panels do badly.
nonisolated enum PlaylistStreamFormat: String, CaseIterable, Identifiable, Codable {
    case automatic
    case hls
    case mpegTS

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .hls: "HLS"
        case .mpegTS: "MPEG-TS"
        }
    }

    /// The next choice, wrapping around — tvOS advances the setting in place
    /// rather than opening a picker.
    var next: PlaylistStreamFormat {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The Xtream path extension this format maps to, or `nil` for `automatic`
    /// — where the caller keeps its own default.
    var xtreamFormat: StreamFormat? {
        switch self {
        case .automatic: nil
        case .hls: .m3u8
        case .mpegTS: .tsStream
        }
    }

    /// Rewrites a provider-supplied live URL to this container.
    ///
    /// Only URLs whose filename already ends in `.m3u8` or `.ts` are touched —
    /// those are the two interchangeable Xtream-style live endpoints. Anything
    /// else (a bare path, an `index.*` segment manifest, a VOD file) is left
    /// alone rather than guessed at, so a mismatched setting can never break a
    /// channel that was playing before.
    func applied(to url: URL) -> URL {
        guard let target = xtreamFormat?.rawValue,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dot = components.path.lastIndex(of: "."),
              !components.path[dot...].contains("/")
        else { return url }
        let current = components.path[components.path.index(after: dot)...].lowercased()
        guard current == "m3u8" || current == "ts", current != target else { return url }
        components.path = String(components.path[..<dot]) + "." + target
        return components.url ?? url
    }
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

    var streamFormat: PlaylistStreamFormat {
        get { PlaylistStreamFormat(rawValue: streamFormatRaw) ?? .automatic }
        set { streamFormatRaw = newValue.rawValue }
    }

    /// Whether the stream container can be chosen for this playlist. Stalker
    /// portals hand out a fully-formed stream URL per session through
    /// `create_link`, so there is nothing for us to pick.
    var supportsStreamFormatChoice: Bool {
        sourceType != .stalker
    }

    /// Whether content from this playlist can be downloaded for offline playback.
    /// Stalker portals hand out short-lived, per-session stream URLs, so there is
    /// no stable URL to persist for offline use.
    var supportsDownloads: Bool {
        sourceType != .stalker
    }
}
