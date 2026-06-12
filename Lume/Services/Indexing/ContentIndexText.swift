//
//  ContentIndexText.swift
//  Lume
//
//  Pure text helpers for the content indexer: cleaning IPTV provider names
//  into TMDB search queries, and assembling the document that gets embedded.
//

import Foundation

nonisolated enum ContentIndexText {
    // MARK: - TMDB search query

    /// Reduces a raw provider name to a searchable title plus release year.
    ///
    /// IPTV providers decorate names with country/quality tags — e.g.
    /// "DE | Der Pate (1972) 4K" or "[MULTI] Inception 2010 FHD". TMDB search
    /// fails on those, so we strip the decorations heuristically: this can
    /// mangle rare titles (an all-caps title before a dash), which simply means
    /// no TMDB match for that item — never wrong data.
    static func searchQuery(for rawName: String) -> (title: String, year: Int?) {
        var name = rawName

        // Bracketed groups are always tags, never part of the title.
        name = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)

        // A year anywhere in the name — prefer the last occurrence (a leading
        // one is more likely part of the title, e.g. "2012"). Only treat it as
        // a release year when it doesn't make up the whole remaining title.
        var year: Int?
        let yearPattern = #"(?:\(\s*((?:19|20)\d{2})\s*\)|\b((?:19|20)\d{2})\b)"#
        if let regex = try? NSRegularExpression(pattern: yearPattern) {
            let fullRange = NSRange(name.startIndex..., in: name)
            let matches = regex.matches(in: name, range: fullRange)
            if let match = matches.last, let range = Range(match.range, in: name) {
                let stripped = name.replacingCharacters(in: range, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    year = Int(name[range].filter(\.isNumber))
                    name = name.replacingCharacters(in: range, with: " ")
                }
            }
        }

        // Leading all-caps/digit provider tags: "DE |", "4K:", "VOD -".
        while let range = name.range(
            of: #"^\s*[A-Z0-9+#]{1,6}\s*[|:•]\s*|^\s*[A-Z0-9+#]{1,6}\s+-\s+"#,
            options: .regularExpression
        ) {
            name.removeSubrange(range)
        }

        // Quality/codec tokens anywhere in the name.
        name = name.replacingOccurrences(
            of: #"(?i)\b(4K|UHD|FHD|HDTV|HD|SD|HEVC|HDR10\+?|HDR|DV|H\.?26[45]|X26[45]|10BIT|MULTI(?:SUB)?|\d{3,4}p)\b"#,
            with: " ",
            options: .regularExpression
        )

        // Collapse leftover separators and whitespace.
        name = name.replacingOccurrences(of: #"\(\s*\)"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:•.").union(.whitespacesAndNewlines))

        return (name.isEmpty ? rawName : name, year)
    }

    // MARK: - Embedding document

    /// The facts about a title that make up its embedding document.
    struct TitleFacts {
        var name: String
        var year: Int?
        var genre: String?
        var tagline: String?
        var plot: String?
        var cast: String?
    }

    /// Assembles the natural-language document that gets embedded for a title.
    /// Most important facts lead, since `NLContextualEmbedding` truncates long
    /// inputs to its maximum token sequence.
    static func document(for facts: TitleFacts) -> String {
        var parts: [String] = []

        var title = facts.name
        if let year = facts.year {
            title += " (\(year))"
        }
        parts.append(title + ".")

        if let genre = facts.genre, !genre.isEmpty {
            parts.append(genre + ".")
        }
        if let tagline = facts.tagline, !tagline.isEmpty {
            parts.append(tagline.hasSuffix(".") ? tagline : tagline + ".")
        }
        if let plot = facts.plot, !plot.isEmpty {
            parts.append(plot)
        }
        if let cast = facts.cast, !cast.isEmpty {
            parts.append("Starring \(cast).")
        }

        return parts.joined(separator: " ")
    }

    /// Parses a year out of a provider release-date string ("2010-07-16",
    /// "2010").
    static func year(fromReleaseDate releaseDate: String?) -> Int? {
        guard let releaseDate,
              let match = releaseDate.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression)
        else { return nil }
        return Int(releaseDate[match])
    }
}
