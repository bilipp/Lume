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
    static let libraries: [Library] = {
        var libraries = [
            Library(name: "KSPlayer", license: "GPL v3", urlString: "https://github.com/kingslay/KSPlayer"),
            Library(name: "FFmpegKit", license: "GPL v3 / LGPL v3", urlString: "https://github.com/kingslay/FFmpegKit"),
            Library(name: "VLCKit", license: "LGPL v2.1", urlString: "https://code.videolan.org/videolan/VLCKit")
        ]
        #if !os(visionOS)
            // The engine's licence asks for the exact tag built against, and
            // FFmpegBuild's tag carries the patched FFmpeg sources the LGPL
            // requires us to point at. Keep both in step with Package.resolved.
            libraries += [
                Library(
                    name: "AetherEngine",
                    license: "LGPL v3 + App Store exception",
                    urlString: "https://github.com/superuser404notfound/AetherEngine/tree/7.53.1"
                ),
                Library(
                    name: "FFmpeg (FFmpegBuild)",
                    license: "LGPL v2.1",
                    urlString: "https://github.com/superuser404notfound/FFmpegBuild/tree/3.11.1"
                ),
                Library(name: "dav1d", license: "BSD 2-Clause", urlString: "https://code.videolan.org/videolan/dav1d"),
                Library(name: "zimg", license: "WTFPL", urlString: "https://github.com/sekrit-twc/zimg"),
                Library(name: "libzvbi", license: "LGPL v2.1 / MIT", urlString: "https://github.com/zapping-vbi/zvbi"),
                Library(name: "libdovi", license: "MIT", urlString: "https://github.com/quietvoid/dovi_tool")
            ]
        #endif
        return libraries
    }()

    // MARK: - Sample footage

    /// The film the Subtitle Style preview takes its still from. Its CC BY 3.0
    /// licence requires this attribution.
    static let sampleFootage = Library(
        name: "Big Buck Bunny",
        license: "CC BY 3.0",
        urlString: "https://peach.blender.org"
    )

    // MARK: - Contributors

    /// A person who contributed to Lume outside the codebase (artwork, design,
    /// etc.). Name is a proper noun — never localised; the contribution copy is
    /// localised in the views.
    struct Contributor: Identifiable {
        /// Proper-noun name — never localised.
        let name: String

        var id: String {
            name
        }
    }

    /// People credited for non-code contributions.
    static let iconColorsContributor = Contributor(name: "Toni")

    // MARK: - Metadata providers (attribution required by their terms)

    static let tmdb = "https://www.themoviedb.org"
    static let mdblist = "https://mdblist.com"
    static let trakt = "https://trakt.tv"
    static let introDB = "https://introdb.app"

    static var tmdbURL: URL? {
        URL(string: tmdb)
    }

    static var mdblistURL: URL? {
        URL(string: mdblist)
    }

    static var traktURL: URL? {
        URL(string: trakt)
    }

    static var introDBURL: URL? {
        URL(string: introDB)
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
