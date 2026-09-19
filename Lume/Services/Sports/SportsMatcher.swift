//
//  SportsMatcher.swift
//  Lume
//
//  Ties a `SportsFixture` from a `SportsDataProvider` to a programme in the
//  user's own EPG, so a fixture can link straight to the channel carrying it.
//  Pure, `nonisolated` logic over plain value types (no SwiftData, no network),
//  fully unit-testable: the SwiftData channel resolver maps its `EPGListing`s to
//  `EPGProgramCandidate`s and passes the fixture in.
//

import Foundation

/// A lightweight, value-type view of an EPG programme for matching.
nonisolated struct EPGProgramCandidate {
    let channelId: String
    let title: String
    let subtitle: String
    let listingDescription: String
    /// XMLTV `<category>` values joined into one string.
    let category: String
    let start: Date
    let end: Date

    init(
        channelId: String,
        title: String,
        subtitle: String = "",
        listingDescription: String = "",
        category: String = "",
        start: Date,
        end: Date
    ) {
        self.channelId = channelId
        self.title = title
        self.subtitle = subtitle
        self.listingDescription = listingDescription
        self.category = category
        self.start = start
        self.end = end
    }
}

/// The EPG programme a fixture was matched to.
nonisolated struct SportMatch: Equatable {
    let channelId: String
    let programTitle: String
    let programStart: Date
    /// Weighted count of distinctive team tokens found — used to break ties
    /// between several programmes in the kickoff window.
    let score: Int
}

nonisolated enum SportsMatcher {
    /// How far before kickoff a broadcast may start (pre-match coverage) and how
    /// far after kickoff a listing may still begin and count as the same match.
    static let leadTime: TimeInterval = 2 * 3600
    static let lateStart: TimeInterval = 30 * 60

    /// A subtitle hit is the fixture line itself ("Arsenal v Chelsea"), so it
    /// weighs more than a title hit, which weighs more than a body-text hit.
    private static let subtitleWeight = 3
    private static let titleWeight = 2
    private static let descriptionWeight = 1
    private static let categoryBonus = 1

    /// Only the head of a listing description is searched — sports bodies front-
    /// load the fixture and bury unrelated names (pundits, other results) later.
    private static let descriptionScanLength = 200

    /// Finds the EPG programme that best carries `fixture` among `candidates`, or
    /// `nil` when none is a confident match.
    ///
    /// A candidate qualifies only when it starts inside the kickoff window **and**
    /// names both teams somewhere in its title, subtitle or the head of its
    /// description. Among the qualifiers it picks the highest weighted score,
    /// breaking ties toward the programme starting closest to kickoff.
    static func bestMatch(
        for fixture: SportsFixture,
        in candidates: [EPGProgramCandidate],
        aliases: SportsTeamAliases = .bundled
    ) -> SportMatch? {
        guard let home = fixture.home?.team, let away = fixture.away?.team else { return nil }
        let homeTokens = tokens(for: home, aliases: aliases)
        let awayTokens = tokens(for: away, aliases: aliases)
        guard !homeTokens.isEmpty, !awayTokens.isEmpty else { return nil }

        let windowStart = fixture.startDate.addingTimeInterval(-leadTime)
        let windowEnd = fixture.startDate.addingTimeInterval(lateStart)

        var best: SportMatch?
        for candidate in candidates {
            guard candidate.start >= windowStart, candidate.start <= windowEnd else { continue }

            let title = normalize(candidate.title)
            let subtitle = normalize(candidate.subtitle)
            let description = normalize(String(candidate.listingDescription.prefix(descriptionScanLength)))

            let home = teamScore(homeTokens, title: title, subtitle: subtitle, description: description)
            let away = teamScore(awayTokens, title: title, subtitle: subtitle, description: description)
            guard home.matched, away.matched else { continue }

            let bonus = mentionsSport(candidate.category) ? categoryBonus : 0
            let candidateMatch = SportMatch(
                channelId: candidate.channelId,
                programTitle: candidate.title,
                programStart: candidate.start,
                score: home.score + away.score + bonus
            )
            if isBetter(candidateMatch, than: best, kickoff: fixture.startDate) {
                best = candidateMatch
            }
        }
        return best
    }

    /// Prefer a higher score; on a tie prefer the programme starting closest to
    /// kickoff.
    private static func isBetter(_ lhs: SportMatch, than rhs: SportMatch?, kickoff: Date) -> Bool {
        guard let rhs else { return true }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsGap = abs(lhs.programStart.timeIntervalSince(kickoff))
        let rhsGap = abs(rhs.programStart.timeIntervalSince(kickoff))
        return lhsGap < rhsGap
    }

    /// A team's weighted score across the fields, and whether it appeared at all.
    /// Fields are pre-normalized haystacks.
    private static func teamScore(
        _ tokens: Set<String>,
        title: String,
        subtitle: String,
        description: String
    ) -> (score: Int, matched: Bool) {
        let titleHits = matchCount(tokens, in: title)
        let subtitleHits = matchCount(tokens, in: subtitle)
        let descriptionHits = matchCount(tokens, in: description)
        let score = titleHits * titleWeight
            + subtitleHits * subtitleWeight
            + descriptionHits * descriptionWeight
        return (score, titleHits > 0 || subtitleHits > 0 || descriptionHits > 0)
    }

    /// Whether the category text names a sport we care about — a small bonus so a
    /// sports-tagged listing outranks a same-name coincidence in generic text.
    private static func mentionsSport(_ category: String) -> Bool {
        let haystack = normalize(category)
        return sportWords.contains { containsWord($0, in: haystack) }
    }

    /// Category words, across the app's languages, for every sport in the
    /// catalogue. Lowercase and accent-free to match `normalize` output.
    private static let sportWords: [String] = [
        "sport", "sports", "deportes", "esporte", "esportes",
        "soccer", "football", "fussball", "futbol", "futebol", "calcio", "voetbal",
        "basketball", "basket", "baloncesto", "basquete",
        "hockey", "eishockey",
        "baseball", "beisbol", "softball",
        "rugby", "afl",
        "lacrosse",
        "motorsport", "racing", "formel", "formula", "formule", "nascar", "indycar",
        "mma", "ufc", "kampfsport", "boxing", "boxen"
    ]

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

    /// Distinctive tokens for a fixture team: its ESPN display name, short name,
    /// its abbreviation (only when ≥3 letters, so "FC"/"AC" don't add noise) and
    /// its aliases, each tokenized and folded, unioned into one set.
    static func tokens(for team: SportsTeam, aliases: SportsTeamAliases = .bundled) -> Set<String> {
        var names = [team.name, team.shortName]
        if team.abbreviation.count >= 3 { names.append(team.abbreviation) }
        names.append(contentsOf: aliases.aliases(for: [team.name, team.shortName]))

        var result: Set<String> = []
        for name in names {
            result.formUnion(tokens(forName: name))
        }
        return result
    }

    /// Distinctive tokens for a single name string: folded, split on word
    /// boundaries, generic affixes and very short tokens dropped. Falls back to
    /// the longer raw tokens when filtering would leave nothing.
    static func tokens(forName name: String) -> Set<String> {
        let raw = normalize(name)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        let meaningful = raw.filter { !stopwords.contains($0) }
        return Set(meaningful.isEmpty ? raw : meaningful)
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
    /// tokens because they're often the *distinguishing* part. Two-letter affixes
    /// (fc, ac, cf…) are already dropped by the length filter. Lowercase and
    /// accent-free to match `normalize` output.
    private static let stopwords: Set<String> = [
        "afc", "ssc", "club", "calcio", "football", "fussball"
    ]
}

/// Bundled team-alias table: provider names/keys → alternate names and exonyms
/// in the app's languages (Napoli → Neapel, Inter Milan → Inter, …). Shipped as
/// `SportsTeamAliases.json`; matching folds each alias through the same
/// tokenizer as a team's own names.
nonisolated struct SportsTeamAliases {
    /// Folded team key → its alias strings.
    private let byKey: [String: [String]]

    init(rawEntries: [String: [String]]) {
        var map: [String: [String]] = [:]
        for (key, values) in rawEntries {
            map[SportsTeamAliases.foldKey(key)] = values
        }
        byKey = map
    }

    /// Aliases for any of `names` (a team's display and short names), deduped.
    func aliases(for names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            for alias in byKey[SportsTeamAliases.foldKey(name)] ?? [] where seen.insert(alias).inserted {
                result.append(alias)
            }
        }
        return result
    }

    /// The lazily loaded, cached table shipped in the app bundle.
    static let bundled = load()

    static func load(bundle: Bundle = .main) -> SportsTeamAliases {
        let candidates = [bundle] + Bundle.allBundles
        for candidate in candidates {
            guard let url = candidate.url(forResource: "SportsTeamAliases", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
            else { continue }
            return SportsTeamAliases(rawEntries: decoded)
        }
        return SportsTeamAliases(rawEntries: [:])
    }

    /// Diacritic/case-folded, whitespace-collapsed key for dictionary lookup.
    private static func foldKey(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
