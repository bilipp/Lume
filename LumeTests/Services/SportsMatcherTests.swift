//
//  SportsMatcherTests.swift
//  LumeTests
//
//  Ported from the closed feat/sport-announcements SportMatcher, adapted to the
//  Sports Hub's `SportsFixture` value type, plus new cases for aliases, exonyms
//  and subtitle weighting.
//

import Foundation
@testable import Lume
import Testing

struct SportsMatcherTests {
    /// A fixed reference kickoff so the time-window assertions are deterministic.
    private let kickoff = Date(timeIntervalSince1970: 1_750_000_000)

    private let noAliases = SportsTeamAliases(rawEntries: [:])

    private func team(_ name: String, short: String? = nil, abbreviation: String = "") -> SportsTeam {
        SportsTeam(
            leagueId: "espn:soccer/eng.1",
            teamId: name,
            name: name,
            shortName: short ?? name,
            abbreviation: abbreviation
        )
    }

    private func fixture(home: String, away: String, kickoff: Date? = nil) -> SportsFixture {
        SportsFixture(
            id: "evt-\(home)-\(away)",
            leagueId: "espn:soccer/eng.1",
            leagueName: "Premier League",
            leagueAbbreviation: "PL",
            startDate: kickoff ?? self.kickoff,
            status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: team(home)),
            away: SportsCompetitor(team: team(away))
        )
    }

    private func candidate(
        _ title: String,
        subtitle: String = "",
        description: String = "",
        category: String = "",
        channel: String = "sky",
        startOffset: TimeInterval = 0
    ) -> EPGProgramCandidate {
        EPGProgramCandidate(
            channelId: channel,
            title: title,
            subtitle: subtitle,
            listingDescription: description,
            category: category,
            start: kickoff.addingTimeInterval(startOffset),
            end: kickoff.addingTimeInterval(startOffset + 7200)
        )
    }

    // MARK: - Token extraction

    @Test func `tokens drop short affixes and fold diacritics`() {
        let tokens = SportsMatcher.tokens(for: team("FC Bayern München"), aliases: noAliases)
        #expect(tokens.contains("munchen"))
        #expect(tokens.contains("bayern"))
        #expect(!tokens.contains("fc"))
    }

    @Test func `tokens keep distinguishing words for same-city clubs`() {
        let real = SportsMatcher.tokens(for: team("Real Madrid"), aliases: noAliases)
        let atletico = SportsMatcher.tokens(for: team("Atlético Madrid"), aliases: noAliases)
        #expect(real.contains("real"))
        #expect(atletico.contains("atletico"))
        #expect(real != atletico)
    }

    @Test func `tokens include a three-letter abbreviation but not a two-letter one`() {
        let withAbbr = SportsMatcher.tokens(for: team("Tottenham", abbreviation: "TOT"), aliases: noAliases)
        #expect(withAbbr.contains("tot"))
        let shortAbbr = SportsMatcher.tokens(for: team("Juventus", abbreviation: "JV"), aliases: noAliases)
        #expect(!shortAbbr.contains("jv"))
    }

    // MARK: - Matching

    @Test func `matches a program naming both teams in the window`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Premier League: Arsenal vs Chelsea", channel: "sky-pl")],
            aliases: noAliases
        )
        #expect(try #require(result).channelId == "sky-pl")
    }

    @Test func `does not match when only one team is present`() {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Premier League: Arsenal vs Tottenham")],
            aliases: noAliases
        )
        #expect(result == nil)
    }

    @Test func `ignores programs outside the kickoff window`() {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Arsenal vs Chelsea", startOffset: -5 * 3600)],
            aliases: noAliases
        )
        #expect(result == nil)
    }

    @Test func `allows pre-match coverage starting before kickoff`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Live: Arsenal v Chelsea", startOffset: -90 * 60)],
            aliases: noAliases
        )
        #expect(try #require(result).channelId == "sky")
    }

    @Test func `picks the program closest to kickoff on a score tie`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [
                candidate("Arsenal vs Chelsea", channel: "early", startOffset: -90 * 60),
                candidate("Arsenal vs Chelsea", channel: "ontime", startOffset: 0)
            ],
            aliases: noAliases
        )
        #expect(try #require(result).channelId == "ontime")
    }

    @Test func `same-city clubs do not cross-match when both names are spelled out`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Atlético Madrid", away: "Real Madrid"),
            in: [
                candidate("Real Madrid vs Barcelona", channel: "wrong"),
                candidate("Atletico Madrid vs Real Madrid", channel: "right")
            ],
            aliases: noAliases
        )
        #expect(try #require(result).channelId == "right")
    }

    @Test func `matches when both teams are named only in the description`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Live Football", description: "Coverage of Arsenal against Chelsea from the Emirates.")],
            aliases: noAliases
        )
        #expect(try #require(result).score > 0)
    }

    @Test func `ignores a team named beyond the description scan head`() {
        let filler = String(repeating: "x ", count: 140)
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Arsenal Preview", description: "Arsenal build-up. \(filler) Chelsea travel here later.")],
            aliases: noAliases
        )
        #expect(result == nil)
    }

    // MARK: - Category bonus

    @Test func `a sports category outranks a bare title match on a tie`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [
                candidate("Arsenal vs Chelsea", channel: "plain"),
                candidate("Arsenal vs Chelsea", category: "Sport / Soccer", channel: "tagged")
            ],
            aliases: noAliases
        )
        #expect(try #require(result).channelId == "tagged")
    }

    @Test func `a non-football sports category earns the same bonus`() throws {
        for category in ["Motorsport", "Basketball", "Eishockey", "Rugby", "Deportes"] {
            let result = SportsMatcher.bestMatch(
                for: fixture(home: "Arsenal", away: "Chelsea"),
                in: [
                    candidate("Arsenal vs Chelsea", channel: "plain"),
                    candidate("Arsenal vs Chelsea", category: category, channel: "tagged")
                ],
                aliases: noAliases
            )
            #expect(try #require(result).channelId == "tagged", "\(category)")
        }
    }

    // MARK: - Subtitle weighting

    @Test func `a subtitle hit outweighs a title hit`() throws {
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [
                candidate("Arsenal vs Chelsea", channel: "title"),
                candidate("Match of the Day", subtitle: "Arsenal vs Chelsea", channel: "subtitle")
            ],
            aliases: noAliases
        )
        #expect(try #require(result).channelId == "subtitle")
    }

    // MARK: - Aliases and exonyms

    @Test func `an exonym in the subtitle matches through the alias table`() {
        let aliases = SportsTeamAliases(rawEntries: [
            "Napoli": ["Neapel"],
            "AC Milan": ["Mailand"]
        ])
        let matched = SportsMatcher.bestMatch(
            for: fixture(home: "Napoli", away: "AC Milan"),
            in: [candidate("Fußball", subtitle: "Neapel gegen Mailand", category: "Fußball")],
            aliases: aliases
        )
        #expect(matched != nil)

        let unmatched = SportsMatcher.bestMatch(
            for: fixture(home: "Napoli", away: "AC Milan"),
            in: [candidate("Fußball", subtitle: "Neapel gegen Mailand", category: "Fußball")],
            aliases: noAliases
        )
        #expect(unmatched == nil)
    }

    @Test func `a short-name alias matches the full club name`() {
        let aliases = SportsTeamAliases(rawEntries: ["Tottenham Hotspur": ["Spurs"]])
        let result = SportsMatcher.bestMatch(
            for: fixture(home: "Tottenham Hotspur", away: "Arsenal"),
            in: [candidate("North London Derby: Spurs v Arsenal")],
            aliases: aliases
        )
        #expect(result != nil)
    }

    @Test func `alias lookup folds diacritics and case in its keys`() {
        let aliases = SportsTeamAliases(rawEntries: ["Atlético Madrid": ["Atleti"]])
        #expect(aliases.aliases(for: ["atletico madrid"]) == ["Atleti"])
    }

    // MARK: - Bundled table

    @Test func `the bundled alias table ships and resolves a known exonym`() {
        let bundled = SportsTeamAliases.bundled
        let napoli = bundled.aliases(for: ["Napoli"])
        #expect(napoli.contains { $0.localizedCaseInsensitiveContains("Neapel") })
    }

    // MARK: - F1 / competitor-less events

    @Test func `a competitor-less event never matches`() {
        let fixture = SportsFixture(
            id: "f1-race",
            leagueId: "espn:racing/f1",
            leagueName: "Formula 1",
            leagueAbbreviation: "F1",
            startDate: kickoff,
            status: SportsFixtureStatus(state: .scheduled)
        )
        #expect(SportsMatcher.bestMatch(for: fixture, in: [candidate("Formula 1: Grand Prix")], aliases: noAliases) == nil)
    }
}
