//
//  LiveStreamURLResolver.swift
//  Lume
//
//  The single answer to "which URL does this live channel play at". Play and
//  Record both go through it, so a recording server is handed exactly the URL
//  the player would open — same container choice, same `allowed_output_formats`
//  fallback, same m3u rewrite.
//

import Foundation

nonisolated enum LiveStreamURLResolver {
    /// The URL Play opens for `stream`. For a Stalker portal this is the
    /// deferred `lumestalker://` placeholder: the real URL comes from
    /// `create_link` at tap time and expires, so it is never built here. Callers
    /// that hand the URL to something other than the player check
    /// `needsTapTimeResolution(_:)` first.
    static func playbackURL(
        for stream: LiveStream,
        playlist: Playlist,
        client: XtreamClient = XtreamClient()
    ) -> URL? {
        if playlist.sourceType == .stalker {
            guard let cmd = stream.directURL else { return nil }
            return StalkerLink.placeholder(type: .itv, cmd: cmd)
        }
        // WebDAV and the media servers deliberately take this direct-URL
        // path too, though none of those playlist kinds has live channels
        // to reach it with.
        // An m3u channel plays at the URL the playlist listed; the chosen
        // container rewrites it only when the provider used one of the two
        // interchangeable live endpoints. Xtream URLs are built with it.
        let directURL = stream.directURL.flatMap(URL.init(string:)).map(playlist.streamFormat.applied(to:))
        return directURL ?? client.buildLiveStreamURL(for: stream, playlist: playlist)
    }

    /// Whether `url` is a placeholder that must go through `create_link`
    /// (`StalkerStreamResolver`) before anything can open it.
    static func needsTapTimeResolution(_ url: URL) -> Bool {
        StalkerLink.isPlaceholder(url)
    }
}
