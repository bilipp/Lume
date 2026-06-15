//
//  Genre.swift
//  Lume
//
//  Genre is stored on Movie and Series as a single string joining several genre
//  names (TMDB enrichment writes `"Action, Sci-Fi"`; m3u/Xtream providers may
//  use other separators). These helpers turn that string into individual genre
//  tokens so the browse and search surfaces can group and filter by genre.
//

import Foundation

/// Splits a provider/TMDB genre string into individual genre tokens.
enum GenreParser {
    /// We split on commas, pipes and slashes — the separators providers actually
    /// use — but deliberately keep `&` intact so multi-word TMDB genres like
    /// "Sci-Fi & Fantasy" and "Action & Adventure" stay whole.
    private static let separators = CharacterSet(charactersIn: ",|/")

    /// The distinct, trimmed genre tokens in `raw`, in their original order.
    static func tokens(from raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.components(separatedBy: separators) {
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, seen.insert(token.lowercased()).inserted else { continue }
            result.append(token)
        }
        return result
    }

    /// The genre to store after seeing a provider (playlist) value, given what is
    /// already set. TMDB is the primary source, so the provider value is a fallback
    /// only: it seeds an empty genre (so something shows before enrichment) but
    /// never overwrites a genre already set — which TMDB enrichment owns and must
    /// keep across re-syncs.
    static func providerFallback(current: String?, provider: String?) -> String? {
        if let current, !current.isEmpty { return current }
        if let provider, !provider.isEmpty { return provider }
        return current
    }

    /// Whether `raw` carries `genre` as a whole token (case-insensitive). Used to
    /// re-filter a `localizedStandardContains` fetch down to exact-token matches,
    /// so a tile for "Action" never sweeps in a stray substring hit.
    static func contains(_ raw: String?, genre: String) -> Bool {
        let needle = genre.lowercased()
        return tokens(from: raw).contains { $0.lowercased() == needle }
    }

    /// Distinct genres across `raws`, ordered most-common first with ties broken
    /// alphabetically. The first-seen casing of each genre is preserved.
    static func distinctByFrequency(_ raws: [String?]) -> [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for raw in raws {
            for token in tokens(from: raw) {
                let key = token.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = token }
            }
        }
        return counts.keys.sorted { lhs, rhs in
            let (lhsCount, rhsCount) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return (display[lhs] ?? "").localizedStandardCompare(display[rhs] ?? "") == .orderedAscending
        }
        .compactMap { display[$0] }
    }
}

/// A genre browse destination, carried as a navigation value so the Movies and
/// Series tabs can each register a `navigationDestination` for it. Mirrors
/// `LibraryCollection`, the value the cross-category rows navigate with.
struct GenreSelection: Hashable {
    let genre: String
    let type: CategoryType
}
