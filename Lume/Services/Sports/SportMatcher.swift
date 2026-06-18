//
//  SportMatcher.swift
//  Lume
//
//  The "hybrid" half of the Upcoming Matches feature: it ties a fixture from the
//  external provider (TheSportsDB) to a program in the user's own EPG, so a match
//  can link straight to the channel that carries it.
//
//  Pure, `nonisolated` logic over plain value types (no SwiftData, no network),
//  so it's fully unit-testable. Callers map their `EPGListing`s to
//  `EPGProgramCandidate`s and pass the fixture in.
//

import Foundation

/// A lightweight, value-type view of an EPG program for matching.
nonisolated struct EPGProgramCandidate {
    let channelId: String
    let title: String
    let listingDescription: String
    let start: Date
    let end: Date

    init(channelId: String, title: String, listingDescription: String = "", start: Date, end: Date) {
        self.channelId = channelId
        self.title = title
        self.listingDescription = listingDescription
        self.start = start
        self.end = end
    }
}

/// The EPG program a fixture was matched to.
nonisolated struct SportMatch: Equatable {
    let channelId: String
    let programTitle: String
    let programStart: Date
    /// How many distinctive team-name tokens were found in the program — used to
    /// break ties between several programs in the kickoff window.
    let score: Int
}

nonisolated enum SportMatcher {
    /// How far before kickoff a broadcast may start (pre-match coverage) and how
    /// far after kickoff a listing may still begin and count as the same match.
    static let leadTime: TimeInterval = 2 * 3600
    static let lateStart: TimeInterval = 30 * 60

    /// Finds the EPG program that best carries `fixture` among `candidates`, or
    /// `nil` when none is a confident match.
    ///
    /// A candidate qualifies only when it starts inside the kickoff window **and**
    /// names both teams. Among the qualifiers it picks the highest token score,
    /// breaking ties toward the program starting closest to kickoff.
    static func bestMatch(for fixture: SportFixture, in candidates: [EPGProgramCandidate]) -> SportMatch? {
        let homeTokens = tokens(for: fixture.homeTeam)
        let awayTokens = tokens(for: fixture.awayTeam)
        guard !homeTokens.isEmpty, !awayTokens.isEmpty else { return nil }

        let windowStart = fixture.kickoff.addingTimeInterval(-leadTime)
        let windowEnd = fixture.kickoff.addingTimeInterval(lateStart)

        var best: SportMatch?
        for candidate in candidates {
            guard candidate.start >= windowStart, candidate.start <= windowEnd else { continue }
            let haystack = normalize("\(candidate.title) \(candidate.listingDescription)")
            let homeHits = matchCount(homeTokens, in: haystack)
            let awayHits = matchCount(awayTokens, in: haystack)
            guard homeHits > 0, awayHits > 0 else { continue }

            let score = homeHits + awayHits
            let candidateMatch = SportMatch(
                channelId: candidate.channelId,
                programTitle: candidate.title,
                programStart: candidate.start,
                score: score
            )
            if isBetter(candidateMatch, than: best, kickoff: fixture.kickoff) {
                best = candidateMatch
            }
        }
        return best
    }

    /// Prefer a higher score; on a tie prefer the program starting closest to
    /// kickoff.
    private static func isBetter(_ lhs: SportMatch, than rhs: SportMatch?, kickoff: Date) -> Bool {
        guard let rhs else { return true }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsGap = abs(lhs.programStart.timeIntervalSince(kickoff))
        let rhsGap = abs(rhs.programStart.timeIntervalSince(kickoff))
        return lhsGap < rhsGap
    }

    /// How many of a team's distinctive tokens appear in the normalized text.
    private static func matchCount(_ tokens: Set<String>, in haystack: String) -> Int {
        tokens.reduce(into: 0) { count, token in
            if containsWord(token, in: haystack) { count += 1 }
        }
    }

    /// Whole-word-ish containment: the token must be bounded by non-letters so
    /// "city" doesn't match inside "velocity". The haystack is already normalized
    /// and space-padded by `normalize`.
    private static func containsWord(_ token: String, in haystack: String) -> Bool {
        haystack.contains(" \(token) ")
    }

    /// Distinctive tokens for a team name: lowercased, accent-folded, with generic
    /// football affixes and very short tokens dropped. Falls back to the longer
    /// raw tokens when filtering would leave nothing (e.g. a name that is all
    /// affixes).
    static func tokens(for team: String) -> Set<String> {
        let raw = normalize(team)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        let meaningful = raw.filter { !stopwords.contains($0) }
        let chosen = meaningful.isEmpty ? raw : meaningful
        return Set(chosen)
    }

    /// Lowercases, strips diacritics, replaces every non-alphanumeric run with a
    /// space, and pads with leading/trailing spaces so `containsWord` can rely on
    /// word boundaries.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let collapsed = String(cleaned).split(separator: " ").joined(separator: " ")
        return " \(collapsed) "
    }

    /// Generic club affixes that don't distinguish one team from another. Kept
    /// minimal and safe: words like "real", "atletico" or "sporting" are left as
    /// tokens because they're often the *distinguishing* part (Real vs Atlético
    /// Madrid). Two-letter affixes (fc, ac, cf…) are already dropped by the
    /// length filter. Lowercase and accent-free to match `normalize` output.
    private static let stopwords: Set<String> = [
        "afc", "ssc", "club", "calcio", "football", "fussball"
    ]
}
