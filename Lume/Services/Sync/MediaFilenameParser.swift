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
        /// The immediate containing folder. Informational only — the walk files
        /// every entry under the share root's name instead, so one series never
        /// scatters across per-folder categories. Never the movie/series
        /// decision: the filename's `SxxExx` token decides that, even inside a
        /// folder called "Movies".
        var group: String?
    }

    /// Extensions the walk treats as playable media. Supersets
    /// `M3UClassifier.vodExtensions` with the container formats a file share
    /// carries but an IPTV provider doesn't serve as VOD.
    static let mediaExtensions: Set<String> = M3UClassifier.vodExtensions.union([
        "ts", "m2ts", "mts", "m2v", "mpv", "ogv", "ogm", "3gp", "divx", "vob", "rmvb", "asf", "f4v"
    ])

    static func parse(filename: String, folder: String? = nil) -> Parsed {
        parse(filename: filename, folders: folder.map { [$0] } ?? [])
    }

    static func parse(filename: String, folders: [String]) -> Parsed {
        let cleaned = cleanedName(from: filename)
        let trimmedParents = folders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let group = trimmedParents.last.flatMap { $0.isEmpty ? nil : $0 }

        if startsWithEpisodeToken(cleaned), !trimmedParents.isEmpty {
            if let folderEpisode = episodeFromFolderName(parents: trimmedParents, filename: cleaned) {
                return Parsed(name: folderEpisode.name, kind: folderEpisode.kind, group: group)
            }
            if let numbered = episodeFromNumberedLayout(filename: cleaned, parents: trimmedParents) {
                return Parsed(name: numbered.name, kind: numbered.kind, group: group)
            }
        }

        if let info = M3UClassifier.episodeInfo(in: cleaned) {
            let series = titlePrefix(of: info.series, allowEmpty: false)
            let title = titlePrefix(of: info.title, allowEmpty: true)
            let kind = Kind.episode(series: series, season: info.season, episode: info.episode, title: title)
            return Parsed(
                name: composedName(series: series, season: info.season, episode: info.episode, title: title),
                kind: kind,
                group: group
            )
        }

        if let folderEpisode = episodeFromFolderName(parents: trimmedParents, filename: cleaned) {
            return Parsed(name: folderEpisode.name, kind: folderEpisode.kind, group: group)
        }

        if let numbered = episodeFromNumberedLayout(filename: cleaned, parents: trimmedParents) {
            return Parsed(name: numbered.name, kind: numbered.kind, group: group)
        }

        let name = movieName(filename: cleaned, rawFilename: filename, parents: trimmedParents)
        return Parsed(name: name, kind: .movie, group: group)
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

    private static func episodeFromFolderName(parents: [String], filename: String) -> (name: String, kind: Kind)? {
        for parent in parents.reversed() {
            let cleanedParent = cleanedName(from: parent)
            guard let info = M3UClassifier.episodeInfo(in: cleanedParent) else { continue }
            let series = titlePrefix(of: info.series, allowEmpty: false)
            guard !series.isEmpty else { continue }
            let title: String
            if startsWithEpisodeToken(filename) {
                let rest = collapsed(titleAfterLeadingToken(filename))
                title = rest.isEmpty || genericFileTitle(rest) ? "" : titlePrefix(of: rest, allowEmpty: true)
            } else {
                let stripped = collapsed(strippingEpisodePrefix(filename))
                title = genericFileTitle(stripped) ? "" : titlePrefix(of: stripped, allowEmpty: true)
            }
            let kind = Kind.episode(series: series, season: info.season, episode: info.episode, title: title)
            return (composedName(series: series, season: info.season, episode: info.episode, title: title), kind)
        }
        return nil
    }

    private static func episodeFromNumberedLayout(filename: String, parents: [String]) -> (name: String, kind: Kind)? {
        guard let leading = leadingEpisodeNumber(filename) else { return nil }
        var season: Int?
        var showFolder: String?
        for parent in parents.reversed() {
            let cleanedParent = cleanedName(from: parent)
            if season == nil, let found = seasonNumber(in: cleanedParent) {
                season = found
                continue
            }
            let candidate = titlePrefix(of: cleanedParent, allowEmpty: false)
            if !candidate.isEmpty, !genericFileTitle(candidate), seasonNumber(in: cleanedParent) == nil {
                showFolder = candidate
                break
            }
        }
        guard let season, let series = showFolder, !series.isEmpty else { return nil }
        let kind = Kind.episode(series: series, season: season, episode: leading.episode, title: leading.title)
        return (composedName(series: series, season: season, episode: leading.episode, title: leading.title), kind)
    }

    private static func movieName(filename: String, rawFilename: String, parents: [String]) -> String {
        let name = titlePrefix(of: filename, allowEmpty: false)
        guard name.isEmpty || genericFileTitle(name) else { return name }
        for parent in parents.reversed() {
            let cleanedParent = cleanedName(from: parent)
            guard seasonNumber(in: cleanedParent) == nil else { continue }
            let candidate = titlePrefix(of: cleanedParent, allowEmpty: false)
            if !candidate.isEmpty, !genericFileTitle(candidate) {
                return candidate
            }
        }
        return name.isEmpty ? rawFilename : name
    }

    private static func genericFileTitle(_ title: String) -> Bool {
        genericFileTitles.contains(title.lowercased())
    }

    private static func strippingEpisodePrefix(_ filename: String) -> String {
        let range = NSRange(filename.startIndex ..< filename.endIndex, in: filename)
        guard let match = episodePrefix.firstMatch(in: filename, range: range),
              let matchRange = Range(match.range, in: filename)
        else { return filename }
        return String(filename[matchRange.upperBound...])
    }

    private static func leadingEpisodeNumber(_ filename: String) -> (episode: Int, title: String)? {
        let range = NSRange(filename.startIndex ..< filename.endIndex, in: filename)
        guard let match = leadingNumber.firstMatch(in: filename, range: range),
              match.range.location == 0,
              let numberRange = Range(match.range(at: 1), in: filename),
              let episode = Int(filename[numberRange])
        else { return nil }
        let rest = String(filename[Range(match.range, in: filename)!.upperBound...])
        let title = titlePrefix(of: collapsed(rest), allowEmpty: true)
        return (episode, title)
    }

    private static func seasonNumber(in folder: String) -> Int? {
        let range = NSRange(folder.startIndex ..< folder.endIndex, in: folder)
        guard let match = seasonFolder.firstMatch(in: folder, range: range),
              let numberRange = Range(match.range(at: 1), in: folder),
              let season = Int(folder[numberRange])
        else { return nil }
        return season
    }

    private static func startsWithEpisodeToken(_ name: String) -> Bool {
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        guard let match = leadingEpisodeToken.firstMatch(in: name, range: range) else { return false }
        return match.range.location == 0
    }

    private static func titleAfterLeadingToken(_ name: String) -> String {
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        guard let match = leadingEpisodeToken.firstMatch(in: name, range: range),
              let matchRange = Range(match.range, in: name)
        else { return name }
        return String(name[matchRange.upperBound...])
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

    private static let genericFileTitles: Set<String> = [
        "video", "movie", "film", "feature", "main", "title", "play", "index", "episode"
    ]

    private static let episodePrefix = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^(?:e|ep|episode|part|pt)\s*\.?\s*\d{1,3}\s*[-–—·:|. ]?"#,
        options: [.caseInsensitive]
    )

    private static let leadingNumber = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^(\d{1,3})(?=[\s\-–—·:|. ]|$)(?:[\s\-–—·:|. ]*)"#
    )

    private static let seasonFolder = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"(?:^|\b)(?:season|s)\s*\.?\s*(\d{1,2})$"#,
        options: [.caseInsensitive]
    )

    private static let leadingEpisodeToken = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\s*(?:s\d{1,3}\s*e\d{1,4}|\d{1,3}\s*x\s*\d{1,4})\b"#,
        options: [.caseInsensitive]
    )
}
