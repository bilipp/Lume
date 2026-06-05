//
//  TitleVideo.swift
//  Lume
//
//  A YouTube video (trailer, teaser, clip…) attached to a movie or series,
//  sourced from TMDB's `videos` payload. Stored on the SwiftData models as a
//  Codable value so the detail screens can render a videos rail without a
//  refetch.
//

import Foundation

/// A single YouTube video associated with a title.
struct TitleVideo: Codable, Hashable, Identifiable {
    /// The YouTube video key (e.g. `d6j_wN1QO7s`).
    let key: String
    /// Human-readable name from TMDB (e.g. "Official Trailer").
    let name: String
    /// The video kind (e.g. "Trailer", "Teaser", "Clip", "Featurette").
    let type: String

    var id: String {
        key
    }

    /// A watch URL that opens in the YouTube app (if installed) or the browser.
    /// Works on iOS/macOS where the system routes the https universal link to
    /// the YouTube app or falls back to a browser. On tvOS there is no browser
    /// and https universal links are not handed off to other apps, so use
    /// ``youtubeAppURLs`` there instead.
    var youtubeURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    /// Custom-scheme deep links into the YouTube app, in priority order. tvOS
    /// has no web browser and does not route https universal links to other
    /// apps, so the custom URL scheme is the only way to hand a trailer off to
    /// the YouTube app there. The schemes used here must also be listed under
    /// `LSApplicationQueriesSchemes` in Info.plist for `canOpenURL` to see them.
    ///
    /// Order matters: `canOpenURL` only matches on the *scheme*, so the first
    /// entry whose scheme resolves is the one we open. The YouTube tvOS app
    /// only parses the full `youtube://www.youtube.com/watch?v=` form — the bare
    /// `youtube://<id>` form opens the app to its home screen without the video
    /// — so the working form must come first.
    var youtubeAppURLs: [URL] {
        [
            "youtube://www.youtube.com/watch?v=\(key)",
            "vnd.youtube://www.youtube.com/watch?v=\(key)"
        ].compactMap { URL(string: $0) }
    }

    /// The default YouTube thumbnail for the video (16:9 with letterboxing).
    var thumbnailURL: URL? {
        URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg")
    }
}
