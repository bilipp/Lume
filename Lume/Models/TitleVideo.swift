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
    var youtubeURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    /// The default YouTube thumbnail for the video (16:9 with letterboxing).
    var thumbnailURL: URL? {
        URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg")
    }
}
