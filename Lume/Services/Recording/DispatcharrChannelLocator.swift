//
//  DispatcharrChannelLocator.swift
//  Lume
//
//  Which Dispatcharr channel a catalog channel is, when its playlist comes
//  from the paired Dispatcharr server itself (same host and port). Pure string
//  work over the playlist and stream URLs, cheap enough for every Record item;
//  only a stream UUID needs the server's channel list, looked up at tap time.
//

import Foundation

nonisolated enum DispatcharrChannelLocator: Hashable {
    /// The server's channel id: an Xtream `stream_id`, or the last component
    /// of an XC-style `/live/<user>/<pass>/<id>` M3U URL.
    case channelID(Int)
    /// A plain M3U output URL, `/proxy/ts/stream/<channel uuid>`.
    case streamUUID(UUID)

    /// `nil` when the playlist isn't served by the server at `baseURL`, or the
    /// channel's URL names no channel of it (an M3U fetched with `direct=true`
    /// lists the providers' own URLs).
    init?(
        sourceType: PlaylistSourceType,
        playlistURL: String,
        streamID: Int,
        directURL: String?,
        baseURL: URL
    ) {
        guard Self.isServed(playlistURL, by: baseURL) else { return nil }
        self.init(servedSourceType: sourceType, streamID: streamID, directURL: directURL, baseURL: baseURL)
    }

    /// The per-channel part of `init(sourceType:playlistURL:streamID:directURL:baseURL:)`,
    /// for a caller that already knows the server at `baseURL` serves the playlist.
    init?(servedSourceType sourceType: PlaylistSourceType, streamID: Int, directURL: String?, baseURL: URL) {
        switch sourceType {
        case .xtream:
            guard streamID > 0 else { return nil }
            self = .channelID(streamID)
        case .m3u:
            guard let directURL, Self.isServed(directURL, by: baseURL),
                  let locator = Self.locator(inStreamURL: directURL)
            else { return nil }
            self = locator
        case .stalker, .webdav, .jellyfin, .emby, .plex, .silo:
            return nil
        }
    }

    /// Same host and port as `baseURL`; a URL without a port uses its scheme's.
    static func isServed(_ urlString: String, by baseURL: URL) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: candidate) else { return false }
        let served = RecordingServerIdentity.hostAndPort(of: url)
        return !served.host.isEmpty && served == RecordingServerIdentity.hostAndPort(of: baseURL)
    }

    static func locator(inStreamURL urlString: String) -> Self? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let components = url.path().split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last else { return nil }
        if components.count >= 4, Array(components.suffix(4).dropLast()) == ["proxy", "ts", "stream"] {
            return UUID(uuidString: String(last)).map(Self.streamUUID)
        }
        if components.count == 4, components[0] == "live" {
            let stem = last.split(separator: ".", maxSplits: 1).first ?? last
            guard let id = Int(stem), id > 0 else { return nil }
            return .channelID(id)
        }
        return nil
    }
}
