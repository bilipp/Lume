//
//  SportsChannelResolver+Competition.swift
//  Lume
//
//  The umbrella fallback: a tour-wide programme that names no match but is on
//  air when it starts — Sky's "Live ATP & WTA: Die Topspiele des Tages", a
//  block running for hours across a whole order of play. It names neither
//  player, so the team matcher can't find it and the kickoff window (which
//  wants a programme *starting* near the match) would drop it anyway.
//

import Foundation

nonisolated extension SportsChannelResolver {
    struct CompetitionHit {
        let score: Int
        let title: String
        let start: Date
    }

    /// The umbrella programme on air at the fixture's start, or `nil`. It must
    /// name the competition in its title or sub-title; naming the tournament
    /// ("Chengdu") adds to the score so the more specific block ranks first.
    static func competitionHit(in candidates: [NormalizedCandidate], fixture: SportsFixture) -> CompetitionHit? {
        let phrases = SportsCompetitionMatcher.phrases(leagueId: fixture.leagueId)
        // A match with no order-of-play slot has a placeholder time; what is on
        // air at that placeholder says nothing about it.
        guard !phrases.isEmpty, fixture.startTimeIsTentative != true else { return nil }
        let kickoff = fixture.startDate
        let tournament = fixture.name.map(SportsCompetitionMatcher.tournamentTokens) ?? []

        var best: CompetitionHit?
        for candidate in candidates {
            // On air at the start, or starting just after it.
            let onAir = candidate.start <= kickoff && candidate.end > kickoff
            let startsSoon = candidate.start > kickoff
                && candidate.start <= kickoff.addingTimeInterval(SportsMatcher.lateStart)
            guard onAir || startsSoon else { continue }
            let headline = candidate.normalizedTitle + candidate.normalizedSubtitle
            guard SportsRaceMatcher.containsAny(phrases, in: headline) else { continue }

            let score = 1 + tournament.count { headline.contains(" \($0) ") } * titleWeight
            if score > (best?.score ?? 0) {
                best = CompetitionHit(score: score, title: candidate.title, start: candidate.start)
            }
        }
        return best
    }
}

/// Words naming a whole competition in a guide headline, for the leagues whose
/// broadcasts cover it as one block rather than match by match.
nonisolated enum SportsCompetitionMatcher {
    static func phrases(leagueId: String) -> [String] {
        switch leagueId {
        case SportsLeague.makeID(sport: "tennis", slug: "atp"): ["atp", "atp tour", "atp masters"]
        case SportsLeague.makeID(sport: "tennis", slug: "wta"): ["wta", "wta tour"]
        default: []
        }
    }

    /// The tournament's distinctive words: "2026 AITO Hangzhou Open" →
    /// {"aito", "hangzhou"}. Years and generic words are dropped.
    static func tournamentTokens(_ name: String) -> Set<String> {
        SportsMatcher.tokens(forName: name).filter { token in
            !genericWords.contains(token) && !token.allSatisfy(\.isNumber)
        }
    }

    private static let genericWords: Set<String> = [
        "open", "championships", "championship", "masters", "tennis", "cup", "classic", "international",
        "internationals", "presented", "grand", "slam", "tour", "atp", "wta", "the"
    ]
}
