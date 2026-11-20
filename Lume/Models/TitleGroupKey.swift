//
//  TitleGroupKey.swift
//  Lume
//
//  The key that groups catalog rows of one title across qualities, languages
//  and playlists. Stored on `Movie.titleGroupKey` / `Series.titleGroupKey`.
//

import Foundation

nonisolated enum TitleGroupKey {
    static let tmdbPrefix = "tmdb:"

    /// `tmdb:<id>` once TMDB resolved the title, else `t:<title>|<year>` from
    /// the provider name with its tags stripped. `nil` (never grouped) when
    /// nothing of the title is left.
    static func movie(tmdbId: Int?, name: String) -> String? {
        key(tmdbId: tmdbId, name: name)
    }

    static func series(tmdbId: Int?, name: String) -> String? {
        key(tmdbId: tmdbId, name: name)
    }

    /// The group key for a row whose `matchKey(name:)` is already derived.
    static func key(tmdbId: Int?, matchKey: String?) -> String? {
        tmdbId.map { "\(tmdbPrefix)\($0)" } ?? matchKey
    }

    /// The TMDB id a `tmdb:<id>` key names; nil for a `t:` key.
    static func tmdbId(groupKey: String?) -> Int? {
        guard let groupKey, groupKey.hasPrefix(tmdbPrefix) else { return nil }
        return Int(groupKey.dropFirst(tmdbPrefix.count))
    }

    /// The name-derived `t:<title>|<year>` key, whatever the row's tmdbId.
    /// `nil` when nothing of the title is left.
    static func matchKey(name: String) -> String? {
        let query = ContentIndexText.searchQuery(for: name)
        let title = normalizedTitle(query.title)
        guard !title.isEmpty else { return nil }
        return "t:\(title)|\(query.year.map(String.init) ?? "")"
    }
}

private nonisolated extension TitleGroupKey {
    static func key(tmdbId: Int?, name: String) -> String? {
        key(tmdbId: tmdbId, matchKey: tmdbId == nil ? matchKey(name: name) : nil)
    }

    /// Case- and diacritic-folded, punctuation reduced to single spaces, so
    /// "Amélie: Part 1" and "amelie - part 1" agree.
    static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
