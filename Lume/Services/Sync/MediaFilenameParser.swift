//
//  MediaFilenameParser.swift
//  Lume
//
//  Turns a raw media filename from a WebDAV share into the name the m3u import
//  pipeline expects. A file share has no group-title, no `type` attribute and
//  no provider ids — everything Lume knows about a title has to come out of the
//  filename, which on a typical NAS is scene-named
//  ("Show.S02E01.1080p.WEB.h264-GROUP.mkv").
//
//  This layer is WebDAV-only on purpose: `M3UClassifier`'s derived series names
//  feed `M3UIdentity.seriesId` for every existing m3u playlist, so teaching it
//  about scene tokens would re-id those rows and orphan their favorites, watch
//  progress and enrichment. Normalize here, then hand the result to the
//  unchanged classifier.
//

import Foundation

nonisolated enum MediaFilenameParser {
    nonisolated enum Kind: Hashable {
        case movie
        case episode(series: String, season: Int, episode: Int, title: String)
    }

    nonisolated struct Parsed: Hashable {
        /// The name handed to the import pipeline as `M3UEntry.name`. For an
        /// episode it keeps a canonical `SxxExx` token so the unchanged
        /// `M3UClassifier` re-derives exactly this split.
        var name: String
        var kind: Kind
        /// The containing folder, passed straight through as the browse
        /// category — the file-share equivalent of m3u's group-title. Never the
        /// movie/series decision: the filename's `SxxExx` token decides that,
        /// even inside a folder called "Movies".
        var group: String?
    }

    /// Extensions the walk treats as playable media. Supersets
    /// `M3UClassifier.vodExtensions` with the container formats a file share
    /// carries but an IPTV provider doesn't serve as VOD.
    static let mediaExtensions: Set<String> = M3UClassifier.vodExtensions.union([
        "ts", "m2ts", "mts", "m2v", "mpv", "ogv", "ogm", "3gp", "divx", "vob", "rmvb", "asf", "f4v"
    ])

    static func parse(filename: String, folder: String? = nil) -> Parsed {
        let cleaned = cleanedName(from: filename)
        let trimmedFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = (trimmedFolder?.isEmpty ?? true) ? nil : trimmedFolder

        if let info = M3UClassifier.episodeInfo(in: cleaned) {
            let series = titlePrefix(of: info.series, allowEmpty: false)
            // The episode title is whatever follows the token, which on a scene
            // name is nothing but release tags — an empty title is the correct
            // answer there, so this is the one segment allowed to collapse.
            let title = titlePrefix(of: info.title, allowEmpty: true)
            let kind = Kind.episode(series: series, season: info.season, episode: info.episode, title: title)
            return Parsed(
                name: composedName(series: series, season: info.season, episode: info.episode, title: title),
                kind: kind,
                group: group
            )
        }

        let name = titlePrefix(of: cleaned, allowEmpty: false)
        return Parsed(name: name.isEmpty ? filename : name, kind: .movie, group: group)
    }

    /// The cleaned title of a raw name that *looks* like a scene filename, or
    /// `nil` when it doesn't. Provider names from m3u/Xtream keep today's
    /// behaviour: only a name with no spaces and repeated `.`/`_` separators
    /// qualifies, because "no TMDB match" is acceptable and wrong data is not.
    static func sceneNormalizedName(_ rawName: String) -> String? {
        guard !rawName.contains(" ") else { return nil }
        let dots = rawName.count(where: { $0 == "." })
        let underscores = rawName.count(where: { $0 == "_" })
        guard dots >= 2 || underscores >= 2 else { return nil }

        let cleaned = cleanedName(from: rawName)
        let title = M3UClassifier.episodeInfo(in: cleaned)?.series ?? cleaned
        let result = titlePrefix(of: title, allowEmpty: false)
        return result.isEmpty ? nil : result
    }

    // MARK: - Normalization steps

    /// Drops the media extension, bracketed tracker/tag groups, and the `.`/`_`
    /// separators scene names use in place of spaces.
    private static func cleanedName(from filename: String) -> String {
        var name = strippingMediaExtension(filename)
        name = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        return collapsed(name)
    }

    /// Only strips a trailing dot-segment that is actually a known media
    /// extension — "The.Bear" must not lose "Bear".
    private static func strippingMediaExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return filename }
        let ext = filename[filename.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }),
              mediaExtensions.contains(ext.lowercased())
        else { return filename }
        return String(filename[..<dot])
    }

    /// Everything before the first quality/source/codec token, minus a trailing
    /// release group. `allowEmpty` is false for a title that has to survive:
    /// a name that is nothing but tokens is left alone rather than emptied.
    private static func titlePrefix(of segment: String, allowEmpty: Bool) -> String {
        var result = segment
        let range = NSRange(result.startIndex ..< result.endIndex, in: result)
        if let match = qualityToken.firstMatch(in: result, range: range),
           let tokenRange = Range(match.range, in: result)
        {
            let head = collapsed(String(result[..<tokenRange.lowerBound]))
            if allowEmpty || !head.isEmpty {
                result = head
            }
        }
        return collapsed(strippingReleaseGroup(result))
    }

    /// Drops a trailing `-GROUP`. Requires an all-caps group *and* a
    /// multi-word head, so hyphenated titles ("X-MEN", "Spider-Man") survive.
    private static func strippingReleaseGroup(_ name: String) -> String {
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        guard let match = releaseGroupToken.firstMatch(in: name, range: range),
              let matchRange = Range(match.range, in: name)
        else { return name }
        let head = name[..<matchRange.lowerBound]
        guard head.contains(" ") else { return name }
        return String(head)
    }

    private static func collapsed(_ name: String) -> String {
        name
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: separators)
    }

    private static func composedName(series: String, season: Int, episode: Int, title: String) -> String {
        let token = String(format: "S%02dE%02d", season, episode)
        return title.isEmpty ? "\(series) \(token)" : "\(series) \(token) \(title)"
    }

    // MARK: - Patterns

    private static let separators = CharacterSet(charactersIn: " -–—·:|.").union(.whitespacesAndNewlines)

    /// The first release tag of a scene name marks the end of the title. Word
    /// boundaries are required: "Cobweb" is not a WEB source, "Blade Runner
    /// 2049" is not a resolution.
    private static let qualityToken = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\b(?:2160p|1080p|720p|480p|web[- ]?dl|webrip|web|bluray|bdrip|hdtv|dvdrip"#
            + #"|x\s?26[45]|h\s?26[45]|hevc|aac\d*|ac3|ddp\d*|dts|atmos|remux|proper|repack)\b"#,
        options: [.caseInsensitive]
    )

    private static let releaseGroupToken = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\s*-\s*[A-Z0-9]{2,12}$"#
    )
}
