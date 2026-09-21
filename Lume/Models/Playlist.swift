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

    /// Jellyfin/Emby session, filled at login and refreshed on every sync. The
    /// access token authenticates stream and image requests; the user id scopes
    /// library queries. Both are device-local (a sibling device re-authenticates
    /// with the mirrored username/password on its next sync), so neither is
    /// mirrored to CloudKit. `nil` for every other source type.
    ///
    /// Named for Jellyfin because that source type shipped first; Emby speaks
    /// the same API and reuses the columns rather than growing a parallel pair.
    var jellyfinAccessToken: String?
    var jellyfinUserId: String?

    /// Plex server token, filled at login and refreshed on every sync. Unlike
    /// the Jellyfin pair this can legitimately stay `nil`: a server with
    /// "allow unauthenticated access on the local network" answers every
    /// request without one. Device-local for the same reason, so it is not
    /// mirrored to CloudKit. `nil` for every other source type.
    var plexAccessToken: String?

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

    /// Creates a WebDAV share playlist. `serverURL` holds the full collection
    /// URL the recursive walk starts at — the share root is not discoverable,
    /// so the user enters the whole path.
    convenience init(name: String, webdavURL: String, username: String = "", password: String = "") {
        self.init(name: name, serverURL: webdavURL, username: username, password: password)
        sourceTypeRaw = PlaylistSourceType.webdav.rawValue
    }

    /// Creates a Jellyfin or Emby server playlist. `serverURL` holds the
    /// server base URL (e.g. `http://192.168.1.10:8096`);
    /// `accessToken`/`userId` are the session from the login handshake. Stored
    /// alongside the password so a rotated or revoked token can be re-issued
    /// on the next sync.
    convenience init(
        name: String,
        mediaServerURL: String,
        flavor: MediaServerFlavor,
        username: String,
        password: String,
        accessToken: String,
        userId: String
    ) {
        self.init(name: name, serverURL: mediaServerURL, username: username, password: password)
        sourceTypeRaw = flavor.sourceType.rawValue
        jellyfinAccessToken = accessToken
        jellyfinUserId = userId
    }

    /// Creates a Plex server playlist. `serverURL` holds the server base URL
    /// (e.g. `http://192.168.1.10:32400`); `accessToken` is the `X-Plex-Token`
    /// the login handshake resolved, or `nil` for a server that allows
    /// unauthenticated access on the local network.
    convenience init(name: String, plexURL: String, username: String = "", accessToken: String?) {
        self.init(name: name, serverURL: plexURL, username: username, password: "")
        sourceTypeRaw = PlaylistSourceType.plex.rawValue
        plexAccessToken = accessToken
    }
}

enum PlaylistSourceType: String, Codable {
    case xtream
    case m3u
    case stalker
    /// Declared after the original three so the raw values already persisted
    /// for those cases keep their meaning. (String raw values, so order is
    /// only a convention — new cases always append here.)
    case webdav
    case jellyfin
    case plex
    case emby

    /// Whether this source is a personal media server — a library of movies
    /// and series that a server application indexes and streams, as opposed
    /// to an IPTV provider or a bare file share. Written as an exhaustive
    /// switch so a future source type cannot inherit a default.
    var isMediaServer: Bool {
        switch self {
        case .jellyfin, .emby, .plex: true
        case .xtream, .m3u, .stalker, .webdav: false
        }
    }

    /// Whether a playlist of this source can ever carry live channels. A file
    /// share has none by definition, and the media servers' Live TV tuner
    /// APIs are not synced — so the generic "sync to load channels" empty
    /// state would send the user into an endless re-sync loop.
    var canCarryLiveChannels: Bool {
        switch self {
        case .xtream, .m3u, .stalker: true
        case .webdav, .jellyfin, .emby, .plex: false
        }
    }
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

    /// The source type, or nil when the stored raw value comes from a newer
    /// build than this one. Callers that would otherwise run the wrong pipeline
    /// against a user's server must branch on this rather than on `sourceType`,
    /// whose `?? .xtream` fallback would send Xtream requests to an unknown
    /// source.
    var knownSourceType: PlaylistSourceType? {
        PlaylistSourceType(rawValue: sourceTypeRaw)
    }

    /// The only form of `serverURL` that may be rendered on screen: any
    /// userinfo credentials are stripped, so a URL that carries them cannot be
    /// shown, screenshotted or read aloud.
    var displayURL: String {
        guard var components = URLComponents(string: serverURL) else { return serverURL }
        components.user = nil
        components.password = nil
        return components.string ?? serverURL
    }

    /// Whether the stream container can be chosen for this playlist. Written as
    /// an exhaustive switch so a future source type cannot inherit a default.
    var supportsStreamFormatChoice: Bool {
        switch sourceType {
        case .xtream, .m3u: true
        // Stalker portals hand out a fully-formed stream URL per session
        // through `create_link`, so there is nothing for us to pick.
        case .stalker: false
        // A WebDAV file is a plain byte range — there is no HLS/MPEG-TS choice
        // to make.
        case .webdav: false
        // A Jellyfin/Emby direct stream is a plain byte range too, and so is
        // a Plex part — transcoding profiles are a later change.
        case .jellyfin, .emby, .plex: false
        }
    }

    /// Whether content from this playlist can be downloaded for offline
    /// playback. Written as an exhaustive switch so a future source type cannot
    /// inherit a default.
    var supportsDownloads: Bool {
        switch sourceType {
        case .xtream, .m3u: true
        // Stalker portals hand out short-lived, per-session stream URLs, so
        // there is no stable URL to persist for offline use.
        case .stalker: false
        // Deferred to a later change: a background URLSession cannot answer an
        // auth challenge after the app is relaunched.
        case .webdav: false
        // Deferred to a later change: downloads need the session token as a
        // header the background session cannot re-issue after relaunch. The
        // same holds for Plex's `X-Plex-Token`.
        case .jellyfin, .emby, .plex: false
        }
    }

    /// Whether a series' episodes are fetched from the provider on demand. The
    /// m3u, WebDAV and media-server pipelines import every episode during sync,
    /// so there is nothing to fetch lazily.
    var supportsPerSeriesEpisodeFetch: Bool {
        sourceType == .xtream || sourceType == .stalker
    }
}
