import Foundation

/// What a Cast receiver is asked to load: one stream plus the metadata its
/// default UI shows. Built only by `CastStreamResolver`, so every request
/// that exists has already passed the castability checks.
nonisolated struct CastMediaRequest: Hashable {
    enum StreamType: Hashable {
        case live
        case buffered
    }

    let contentURL: URL
    let contentType: String
    let streamType: StreamType
    let title: String
    let subtitle: String?
    let posterURL: URL?
    /// Seconds into the item the receiver starts at; always 0 for live.
    let startTime: TimeInterval
    /// The catalog identity watch progress is committed against when the cast
    /// ends, which can be long after the player that started it has closed.
    let contentRef: PlayableMedia.ContentRef
}

nonisolated extension CastMediaRequest {
    /// The MIME type the receiver needs to pick a player for `url`. A URL
    /// without a recognised extension is guessed from `kind`: extensionless
    /// live endpoints are Xtream-style MPEG-TS, on-demand files are MP4.
    static func contentType(for url: URL, kind: PlayableMedia.Kind) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": "application/x-mpegURL"
        case "mpd": "application/dash+xml"
        case "mp4", "m4v": "video/mp4"
        case "ts": "video/mp2t"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        default: kind == .live ? "video/mp2t" : "video/mp4"
        }
    }

    /// The artwork URL the receiver can load. Receiver pages are served over
    /// HTTPS and block plain-HTTP images as mixed content, so an `http` poster
    /// is asked for over `https` — failing there is no worse than being
    /// blocked.
    static func receiverPosterURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            return url
        case "http":
            components.scheme = "https"
            return components.url
        default:
            return nil
        }
    }
}
