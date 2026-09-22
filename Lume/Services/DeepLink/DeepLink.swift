//
//  DeepLink.swift
//  Lume
//
//  Custom URL-scheme deep links. `lume://movie/{tmdbId}` and
//  `lume://series/{tmdbId}` open a title's detail screen directly;
//  `lume://play/{movie|episode|live}/{catalogId}` and
//  `lume://open/series/{catalogId}` are emitted by the widgets / Top Shelf
//  (built in `WidgetDeepLink`) and launch playback or a detail screen;
//  `lume://resume` and `lume://downloads` are the Live Activities' tap targets.
//

import Foundation

/// A parsed `lume://` deep link. Parsing is pure (it never touches the catalog)
/// so it can be unit-tested in isolation; resolving the link to a catalog item
/// and driving navigation happens in `MainTabView`.
nonisolated enum DeepLink: Equatable {
    case movie(tmdbId: Int)
    case series(tmdbId: Int)
    case playMovie(id: String)
    case playEpisode(id: String)
    case playLive(id: String)
    case openSeries(id: String)
    /// Reopens the player on the last played stream — the Live Activity's
    /// tap target (see `PlaybackLiveActivity` / `PlaybackResumeStore`).
    case resume
    /// Opens the downloads list — the download Live Activity's tap target
    /// (see `DownloadLiveActivity`).
    case downloads

    /// The app's registered URL scheme (see `CFBundleURLTypes` in Info.plist).
    static let scheme = "lume"

    /// Parses every supported `lume://` form. Returns nil for any other scheme,
    /// an unknown kind, or a malformed id.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        if let activity = Self.activity(host: url.host()) {
            self = activity
            return
        }
        // For `lume://movie/123` the kind is the host and the id is the first
        // path component; `pathComponents` includes the leading "/" and returns
        // components percent-decoded (widget links encode their catalog ids).
        let components = url.pathComponents.filter { $0 != "/" }
        guard let link = Self.catalog(host: url.host(), components: components) else { return nil }
        self = link
    }

    /// The host-only links — the Live Activities' tap targets, with no path.
    private static func activity(host: String?) -> DeepLink? {
        switch host?.lowercased() {
        case "resume": .resume
        case "downloads": .downloads
        default: nil
        }
    }

    /// The catalog links: `movie/` and `series/` by TMDB id, `play/` and
    /// `open/` by catalog id (the widgets' and Top Shelf's links).
    private static func catalog(host: String?, components: [String]) -> DeepLink? {
        switch host?.lowercased() {
        case "movie":
            guard let tmdbId = components.first.flatMap(Int.init) else { return nil }
            return .movie(tmdbId: tmdbId)
        case "series":
            guard let tmdbId = components.first.flatMap(Int.init) else { return nil }
            return .series(tmdbId: tmdbId)
        case "play":
            return play(components)
        case "open":
            guard components.count == 2, components[0].lowercased() == "series" else { return nil }
            return .openSeries(id: components[1])
        default:
            return nil
        }
    }

    /// `play/{movie|episode|live}/{catalogId}` — built by `WidgetDeepLink.play`.
    private static func play(_ components: [String]) -> DeepLink? {
        guard components.count == 2 else { return nil }
        return switch components[0].lowercased() {
        case "movie": .playMovie(id: components[1])
        case "episode": .playEpisode(id: components[1])
        case "live": .playLive(id: components[1])
        default: nil
        }
    }
}

/// The main tab bar's selectable tabs. Hoisted out of `MainTabView` so a deep
/// link can switch tabs through `DeepLinkRouter`.
nonisolated enum AppTab: Hashable {
    case search, home, movies, series, liveTV, sports, settings
}
