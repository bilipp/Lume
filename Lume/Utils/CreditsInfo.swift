//
//  CreditsInfo.swift
//  Lume
//
//  Canonical credits / licensing links, shared by the iOS Settings list
//  (tappable Link rows) and the tvOS About pane (read-only rows, since Apple TV
//  can't open a URL itself). One source of truth so the two surfaces — and the
//  licences they advertise — can never drift. Library names, licence names and
//  URLs are verbatim data; the surrounding descriptive copy is localised in the
//  views (the same split as SupportInfo).
//

import Foundation

nonisolated enum CreditsInfo {
    /// An open-source dependency shipped inside the app.
    struct Library: Identifiable {
        /// Proper-noun product name — never localised.
        let name: String
        /// Short SPDX-ish licence label, e.g. "GPL v3" — never localised.
        let license: String
        /// Home / repository URL.
        let urlString: String

        var id: String {
            name
        }

        var url: URL? {
            URL(string: urlString)
        }

        /// Scheme-stripped form for compact on-screen display.
        var displayURL: String {
            (url?.host()).map { host in
                let path = url?.path() ?? ""
                return path.isEmpty || path == "/" ? host : host + path
            } ?? urlString
        }
    }

    /// Playback engines and the media stack they bundle. Lume itself is licensed
    /// under the GNU AGPL v3 (see `sourceCodeURL` / `licenseURL`); these are the
    /// third-party components whose licences require acknowledgement.
    static let libraries: [Library] = [
        Library(name: "KSPlayer", license: "GPL v3", urlString: "https://github.com/kingslay/KSPlayer"),
        Library(name: "FFmpegKit", license: "GPL v3 / LGPL v3", urlString: "https://github.com/kingslay/FFmpegKit"),
        Library(name: "VLCKit", license: "LGPL v2.1", urlString: "https://github.com/virtualox/vlckit-spm")
    ]

    // MARK: - Metadata providers (attribution required by their terms)

    static let tmdb = "https://www.themoviedb.org"
    static let omdb = "https://www.omdbapi.com"
    static let trakt = "https://trakt.tv"

    static var tmdbURL: URL? {
        URL(string: tmdb)
    }

    static var omdbURL: URL? {
        URL(string: omdb)
    }

    static var traktURL: URL? {
        URL(string: trakt)
    }

    // MARK: - Lume

    static let licenseName = "GNU AGPL v3"
    static let sourceCode = "https://github.com/bilipp/Lume"
    static let licenseURLString = "https://github.com/bilipp/Lume/blob/main/LICENSE"

    static var sourceCodeURL: URL? {
        URL(string: sourceCode)
    }

    static var licenseURL: URL? {
        URL(string: licenseURLString)
    }
}
