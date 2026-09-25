//
//  SportsTennis.swift
//  Lume
//
//  What tennis adds to the provider-neutral sports model: per-set scores, the
//  tour's singles draw, and the lines a match card needs that a team fixture
//  doesn't — the score set by set and the tournament and its round.
//

import Foundation

/// One set of a tennis match from one player's side: the games won, plus the
/// tiebreak points when the set went to one.
nonisolated struct SportsSetScore: Codable, Hashable {
    let games: Int
    let tiebreak: Int?

    init(games: Int, tiebreak: Int? = nil) {
        self.games = games
        self.tiebreak = tiebreak
    }
}

nonisolated extension SportsLeague {
    var isTennis: Bool {
        sport == "tennis"
    }

    /// The tour's own singles draw — the ATP's men's, the WTA's women's — the one
    /// grouping of a tennis event the hub shows.
    var tennisSinglesDraw: String? {
        switch (sport, slug) {
        case ("tennis", "atp"): "mens-singles"
        case ("tennis", "wta"): "womens-singles"
        default: nil
        }
    }
}

nonisolated extension SportsFixture {
    /// A tennis match set by set from the first-listed player's side, tiebreaks
    /// in brackets: "6-4 6-7(5) 7-5". `nil` for other sports and before play.
    var setsLine: String? {
        guard let homeSets = home?.sets, let awaySets = away?.sets, !homeSets.isEmpty else { return nil }
        return zip(homeSets, awaySets).map { home, away in
            // Both sides carry tiebreak points; convention quotes the loser's.
            let tiebreak = home.games < away.games ? home.tiebreak : away.tiebreak
            let base = "\(home.games)-\(away.games)"
            return tiebreak.map { "\(base)(\($0))" } ?? base
        }.joined(separator: " ")
    }

    /// The tournament and its stage for a tennis match — "China Open ·
    /// Quarterfinal" — which the tour name alone doesn't say.
    var tournamentLine: String? {
        guard sport == "tennis", let name else { return nil }
        guard let round else { return name }
        return "\(name) · \(SportsRoundLabel.localized(round))"
    }
}

// MARK: - Tournament rounds

nonisolated enum SportsRoundLabel {
    /// ESPN's English round names ("Round 2", "Quarterfinal"), localised; an
    /// unknown name is shown as sent.
    static func localized(_ round: String) -> String {
        let lower = round.lowercased()
        if let fixed = fixedRounds[lower] { return String(localized: fixed) }
        if lower.hasPrefix("round "), let number = Int(lower.dropFirst("round ".count)) {
            return String(localized: "Round \(number)")
        }
        return round
    }

    /// Keyed, since the bare "Final" is already the finished-game status
    /// ("Beendet"), which is not what a tournament's last round is called.
    private static let fixedRounds: [String: LocalizedStringResource] = [
        "final": LocalizedStringResource("sports.round.final", defaultValue: "Final"),
        "semifinal": LocalizedStringResource("sports.round.semifinal", defaultValue: "Semifinal"),
        "quarterfinal": LocalizedStringResource("sports.round.quarterfinal", defaultValue: "Quarterfinal")
    ]
}
