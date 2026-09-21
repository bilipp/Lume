//
//  ESPNClientRacingTests.swift
//  LumeTests
//
//  The parts of `ESPNClient`'s mapping that only the non-football sports
//  exercise: race-weekend sessions (including sprint weekends), driver tables
//  under a generic standings group, root-level single tables and rugby's stat
//  names. Split from `ESPNClientTests` to keep that suite under the length cap.
//

import Foundation
@testable import Lume
import Testing

/// Serialized: the standings cases share `StubURLProtocol`'s host + path route
/// space and must not register concurrently.
@Suite(.serialized)
struct ESPNClientRacingTests {
    private let siteHost = "site.api.espn.com"
    private let webHost = "site.web.api.espn.com"

    private func f1League() -> SportsLeague {
        SportsLeague(sport: "racing", slug: "f1", name: "Formula 1", abbreviation: "F1", region: .motorsport)
    }

    private func league(sport: String, slug: String) -> SportsLeague {
        SportsLeague(sport: sport, slug: slug, name: slug, abbreviation: slug.uppercased(), region: .rugby)
    }

    // MARK: - Race weekends

    @Test func `f1 scoreboard maps the weekend sessions`() async throws {
        let body = """
        {"leagues": [{"name": "Formula 1", "abbreviation": "F1"}],
         "events": [{"id": "600", "date": "2026-05-22T11:30Z", "name": "Monaco Grand Prix", "shortName": "Monaco GP",
           "circuit": {"fullName": "Circuit de Monaco"},
           "status": {"type": {"state": "pre", "detail": "Sun, May 24", "shortDetail": "5/24"}},
           "competitions": [
             {"type": {"abbreviation": "FP1"}, "date": "2026-05-22T11:30Z"},
             {"type": {"abbreviation": "FP2"}, "date": "2026-05-22T15:00Z"},
             {"type": {"abbreviation": "FP3"}, "date": "2026-05-23T10:30Z"},
             {"type": {"abbreviation": "Qual"}, "date": "2026-05-23T14:00Z"},
             {"type": {"abbreviation": "Race"}, "date": "2026-05-24T13:00Z"}
           ]}]}
        """
        StubURLProtocol.register(host: siteHost, query: (name: "dates", value: "202605"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let fixtures = try await client.fixtures(league: f1League(), month: DateComponents(year: 2026, month: 5))

        #expect(fixtures.count == 1)
        let race = try #require(fixtures.first)
        #expect(race.home == nil)
        #expect(race.away == nil)
        #expect(race.sessions.count == 5)
        #expect(race.sessions.first?.kind == .fp1)
        #expect(race.sessions.last?.kind == .race)
        #expect(race.name == "Monaco Grand Prix")
        #expect(race.shortName == "Monaco GP")
        #expect(race.venue == "Circuit de Monaco")
        #expect(race.hasTeams == false)
        #expect(race.eventTitle == "Monaco Grand Prix")
        #expect(race.eventShortTitle == "Monaco GP")
        #expect(race.eventSubtitle == "Circuit de Monaco")
        // ESPN dates the event at first practice; cards headline the race, two
        // days later.
        #expect(race.raceSession?.kind == .race)
        #expect(race.headlineDate == race.sessions.last?.date)
        #expect(race.headlineIsOnAnotherDay)
    }

    @Test func `a sprint weekend maps its sprint sessions`() async throws {
        let body = """
        {"leagues": [{"name": "Formula 1", "abbreviation": "F1"}],
         "events": [{"id": "601", "date": "2026-10-09T08:30Z", "name": "Singapore Grand Prix",
           "status": {"type": {"state": "pre"}},
           "competitions": [
             {"type": {"abbreviation": "FP1"}, "date": "2026-10-09T08:30Z"},
             {"type": {"abbreviation": "SS"}, "date": "2026-10-09T12:30Z"},
             {"type": {"abbreviation": "SR"}, "date": "2026-10-10T09:00Z"},
             {"type": {"abbreviation": "Qual"}, "date": "2026-10-10T13:00Z"},
             {"type": {"abbreviation": "Race"}, "date": "2026-10-11T12:00Z"}
           ]}]}
        """
        StubURLProtocol.register(host: siteHost, query: (name: "dates", value: "202610"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let fixtures = try await client.fixtures(league: f1League(), month: DateComponents(year: 2026, month: 10))

        let weekend = try #require(fixtures.first)
        #expect(weekend.sessions.map(\.kind) == [.fp1, .sprintQualifying, .sprint, .qualifying, .race])
    }

    // MARK: - Standings across sports

    @Test func `athlete entries under a generic standings group map to driver rows`() async throws {
        let body = """
        {"children": [{"name": "Standings", "standings": {"entries": [
          {"athlete": {"id": "4", "displayName": "Kyle Larson"}, "stats": [
            {"name": "rank", "abbreviation": "RK", "displayValue": "1", "value": 1},
            {"name": "championshipPts", "abbreviation": "PTS", "displayValue": "2168", "value": 2168}
          ]},
          {"athlete": {"id": "9", "displayName": "Chase Elliott"}, "stats": [
            {"name": "rank", "abbreviation": "RK", "displayValue": "2", "value": 2},
            {"name": "championshipPts", "abbreviation": "PTS", "displayValue": "2101", "value": 2101}
          ]}
        ]}}]}
        """
        StubURLProtocol.register(host: webHost, pathSuffix: "/racing/nascar-premier/standings", response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: league(sport: "racing", slug: "nascar-premier"))

        #expect(rows.count == 2)
        let leader = try #require(rows.first)
        #expect(leader.kind == .driver)
        #expect(leader.name == "Kyle Larson")
        #expect(leader.rank == 1)
        #expect(leader.points == 2168)
        #expect(rows[1].rank == 2)
    }

    @Test func `a single table at the response root maps like a group`() async throws {
        let body = """
        {"children": [], "standings": {"entries": [
          {"team": {"id": "2", "displayName": "Fremantle Dockers"}, "stats": [
            {"name": "gamesPlayed", "abbreviation": "P", "displayValue": "23", "value": 23},
            {"name": "wins", "abbreviation": "W", "displayValue": "19", "value": 19},
            {"name": "losses", "abbreviation": "L", "displayValue": "4", "value": 4},
            {"name": "ties", "abbreviation": "D", "displayValue": "0", "value": 0},
            {"name": "pointDifferential", "abbreviation": "DIFF", "displayValue": "+620", "value": 620},
            {"name": "points", "abbreviation": "TP", "displayValue": "76", "value": 76},
            {"name": "rank", "abbreviation": "RNK", "displayValue": "1", "value": 1}
          ]}
        ]}}
        """
        StubURLProtocol.register(host: webHost, pathSuffix: "/australian-football/afl/standings", response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: league(sport: "australian-football", slug: "afl"))

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == .team)
        #expect(row.teamId == "2")
        #expect(row.played == 23)
        #expect(row.wins == 19)
        #expect(row.losses == 4)
        #expect(row.goalDifference == 620)
        #expect(row.points == 76)
    }

    @Test func `several standings groups keep their names and split into tables`() async throws {
        let body = """
        {"children": [
          {"name": "Driver Standings", "standings": {"entries": [
            {"athlete": {"id": "1", "displayName": "Max Verstappen"}, "stats": [
              {"name": "rank", "value": 1}, {"name": "championshipPts", "value": 300}]},
            {"athlete": {"id": "2", "displayName": "Lando Norris"}, "stats": [
              {"name": "rank", "value": 2}, {"name": "championshipPts", "value": 280}]}
          ]}},
          {"name": "Constructor Standings", "standings": {"entries": [
            {"team": {"id": "10", "displayName": "McLaren"}, "stats": [
              {"name": "rank", "value": 1}, {"name": "points", "value": 500}]}
          ]}}
        ]}
        """
        StubURLProtocol.register(host: webHost, pathSuffix: "/racing/f1/standings", response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: f1League())
        let groups = SportsStandingRow.grouped(rows)

        #expect(rows.count == 3)
        #expect(rows.map(\.group) == ["Driver Standings", "Driver Standings", "Constructor Standings"])
        #expect(groups.count == 2)
        #expect(groups[0].kind == .driver)
        #expect(groups[0].rows.map(\.rank) == [1, 2])
        #expect(groups[1].kind == .constructor)
        #expect(groups[1].name == "Constructor Standings")
        #expect(groups[1].rows.first?.rank == 1)
    }

    @Test func `rugby stat names map to the shared columns`() async throws {
        let body = """
        {"children": [{"name": "Top 14", "standings": {"entries": [
          {"team": {"id": "25", "displayName": "Stade Toulousain"}, "stats": [
            {"name": "gamesPlayed", "abbreviation": "GP", "displayValue": "26", "value": 26},
            {"name": "gamesWon", "abbreviation": "W", "displayValue": "17", "value": 17},
            {"name": "gamesDrawn", "abbreviation": "D", "displayValue": "1", "value": 1},
            {"name": "gamesLost", "abbreviation": "L", "displayValue": "8", "value": 8},
            {"name": "pointsDifference", "abbreviation": "PD", "displayValue": "+208", "value": 208},
            {"name": "points", "abbreviation": "P", "displayValue": "81", "value": 81},
            {"name": "rank", "abbreviation": "R", "displayValue": "1", "value": 1}
          ]}
        ]}}]}
        """
        StubURLProtocol.register(host: webHost, pathSuffix: "/rugby/270559/standings", response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: league(sport: "rugby", slug: "270559"))

        let row = try #require(rows.first)
        #expect(row.played == 26)
        #expect(row.wins == 17)
        #expect(row.draws == 1)
        #expect(row.losses == 8)
        #expect(row.goalDifference == 208)
        #expect(row.points == 81)
    }
}
