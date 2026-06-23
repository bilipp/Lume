//
//  DeepLink.swift
//  Lume
//
//  Custom URL-scheme deep links. `lume://movie/{tmdbId}` and
//  `lume://series/{tmdbId}` open a title's detail screen directly.
//

import Foundation

/// A parsed `lume://` deep link. Parsing is pure (it never touches the catalog)
/// so it can be unit-tested in isolation; resolving the link to a catalog item
/// and driving navigation happens in `MainTabView`.
nonisolated enum DeepLink: Equatable {
    case movie(tmdbId: Int)
    case series(tmdbId: Int)

    /// The app's registered URL scheme (see `CFBundleURLTypes` in Info.plist).
    static let scheme = "lume"

    /// Parses `lume://movie/{tmdbId}` and `lume://series/{tmdbId}`. Returns nil
    /// for any other scheme, an unknown kind, or a non-numeric id.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // For `lume://movie/123` the kind is the host and the id is the first
        // path component; `pathComponents` includes the leading "/".
        guard let idComponent = url.pathComponents.first(where: { $0 != "/" }),
              let tmdbId = Int(idComponent)
        else { return nil }
        switch url.host()?.lowercased() {
        case "movie": self = .movie(tmdbId: tmdbId)
        case "series": self = .series(tmdbId: tmdbId)
        default: return nil
        }
    }
}

/// The main tab bar's selectable tabs. Hoisted out of `MainTabView` so a deep
/// link can switch tabs through `DeepLinkRouter`.
nonisolated enum AppTab: Hashable {
    case search, home, movies, series, liveTV, settings
}
