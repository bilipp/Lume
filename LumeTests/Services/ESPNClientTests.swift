//
//  ESPNClientTests.swift
//  LumeTests
//
//  Covers `ESPNClient`'s ESPN-JSON → `Sports*` mapping and its degrade-to-empty
//  contract. Requests are served by `StubURLProtocol`, which routes on host plus
//  one query item, so each test keys its stub on a distinct `dates`/`limit`/
//  `level`/`event` value and the returned fixture doubles as proof that the client
//  built the expected URL shape (`?dates=YYYYMM` vs `?dates=YYYYMMDD`).
//

import Foundation
@testable import Lume
import Testing

/// Serialized because the two standings cases necessarily share the same stub
/// route key (host + standings path), so they must not register concurrently.
@Suite(.serialized)
struct ESPNClientTests {
    private let siteHost = "site.api.espn.com"
    private let webHost = "site.web.api.espn.com"

    private func soccerLeague() -> SportsLeague {
        SportsLeague(sport: "soccer", slug: "ger.1", name: "Bundesliga", abbreviation: "BUND", region: .germany)
    }

    private func f1League() -> SportsLeague {
        SportsLeague(sport: "racing", slug: "f1", name: "Formula 1", abbreviation: "F1", region: .motorsport)
    }

    private func league(sport: String, slug: String) -> SportsLeague {
        SportsLeague(sport: sport, slug: slug, name: slug, abbreviation: slug.uppercased(), region: .rugby)
    }

    private func utcDay(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    // MARK: - Scoreboard (month)

    private static let bundesligaScoreboardJSON = """
    {
      "leagues": [{"name": "German Bundesliga", "abbreviation": "GER", "slug": "ger.1"}],
      "events": [{
        "id": "401773",
        "date": "2026-09-18T18:30Z",
        "name": "Bayern vs Dortmund",
        "status": {"type": {"state": "in", "completed": false, "detail": "45'", "shortDetail": "45'"}},
        "competitions": [{
          "id": "401773",
          "date": "2026-09-18T18:30Z",
          "venue": {"fullName": "Allianz Arena"},
          "broadcasts": [{"names": ["Sky Sport"]}],
          "competitors": [
            {"homeAway": "home", "score": "2", "winner": true, "form": "WWDWL",
             "records": [{"type": "total", "summary": "3-1-0"}],
             "team": {"id": "132", "displayName": "Bayern Munich", "shortDisplayName": "Bayern",
                      "abbreviation": "BAY", "color": "dc052d", "alternateColor": "ffffff",
                      "logo": "https://a.espncdn.com/bay.png"}},
            {"homeAway": "away", "score": "1", "winner": false, "form": "WLLWD",
             "records": [{"type": "total", "summary": "2-1-1"}],
             "team": {"id": "124", "displayName": "Borussia Dortmund", "shortDisplayName": "Dortmund",
                      "abbreviation": "DOR", "color": "fde100", "alternateColor": "000000",
                      "logo": "https://a.espncdn.com/bvb.png"}}
          ]
        }]
      }]
    }
    """

    @Test func `month scoreboard maps competitors, colours, form, records and status`() async throws {
        let body = Self.bundesligaScoreboardJSON
        StubURLProtocol.register(host: siteHost, query: (name: "dates", value: "202609"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let fixtures = try await client.fixtures(league: soccerLeague(), month: DateComponents(year: 2026, month: 9))

        #expect(fixtures.count == 1)
        let fixture = try #require(fixtures.first)
        #expect(fixture.id == "401773")
        // The catalogue's curated labels win over the response's own.
        #expect(fixture.leagueName == "Bundesliga")
        #expect(fixture.leagueAbbreviation == "BUND")
        #expect(fixture.status.state == .inProgress)
        #expect(fixture.status.detail == "45'")
        #expect(fixture.venue == "Allianz Arena")
        #expect(fixture.broadcasters == ["Sky Sport"])
        #expect(fixture.startDate != .distantPast)

        let home = try #require(fixture.home)
        #expect(home.team.name == "Bayern Munich")
        #expect(home.team.id == "espn:soccer/ger.1:132")
        #expect(home.team.colorHex == "dc052d")
        #expect(home.team.alternateColorHex == "ffffff")
        #expect(home.score == 2)
        #expect(home.isWinner == true)
        #expect(home.form == "WWDWL")
        #expect(home.record == "3-1-0")

        let away = try #require(fixture.away)
        #expect(away.team.name == "Borussia Dortmund")
        #expect(away.score == 1)
        #expect(away.isWinner == false)
    }

    // MARK: - Scoreboard (day)

    @Test func `day scoreboard uses the YYYYMMDD dates shape`() async throws {
        let body = """
        {"events": [{"id": "555", "date": "2026-09-18T18:30Z",
          "status": {"type": {"state": "post", "completed": true, "detail": "FT", "shortDetail": "FT"}},
          "competitions": [{"competitors": [
            {"homeAway": "home", "score": "3", "team": {"id": "10", "displayName": "Home FC"}},
            {"homeAway": "away", "score": "0", "team": {"id": "20", "displayName": "Away FC"}}
          ]}]}]}
        """
        StubURLProtocol.register(host: siteHost, query: (name: "dates", value: "20260918"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let fixtures = try await client.fixtures(league: soccerLeague(), day: utcDay(year: 2026, month: 9, day: 18))

        #expect(fixtures.count == 1)
        let fixture = try #require(fixtures.first)
        #expect(fixture.id == "555")
        #expect(fixture.status.state == .final)
        #expect(fixture.home?.score == 3)
    }

    @Test func `postponed status maps to postponed`() async throws {
        let body = """
        {"events": [{"id": "77", "date": "2026-09-18T18:30Z",
          "status": {"type": {"state": "post", "completed": false, "detail": "Postponed", "shortDetail": "Postponed"}},
          "competitions": [{"competitors": [
            {"homeAway": "home", "team": {"id": "10", "displayName": "Home FC"}},
            {"homeAway": "away", "team": {"id": "20", "displayName": "Away FC"}}
          ]}]}]}
        """
        StubURLProtocol.register(host: siteHost, query: (name: "dates", value: "20261001"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let fixtures = try await client.fixtures(league: soccerLeague(), day: utcDay(year: 2026, month: 10, day: 1))
        #expect(fixtures.first?.status.state == .postponed)
        #expect(fixtures.first?.home?.score == nil)
    }

    // MARK: - Teams

    @Test func `teams maps crests, dark crests and colours`() async throws {
        let body = """
        {"sports": [{"leagues": [{"teams": [
          {"team": {"id": "132", "displayName": "Bayern Munich", "shortDisplayName": "Bayern",
                    "abbreviation": "BAY", "color": "dc052d", "alternateColor": "ffffff",
                    "logos": [
                      {"href": "https://a/full.png", "rel": ["full", "default"]},
                      {"href": "https://a/dark.png", "rel": ["full", "dark"]}
                    ]}},
          {"team": {"id": "124", "displayName": "Borussia Dortmund", "shortDisplayName": "Dortmund",
                    "abbreviation": "DOR", "color": "fde100", "alternateColor": "000000",
                    "logos": [{"href": "https://a/bvb.png", "rel": ["full", "default"]}]}}
        ]}]}]}
        """
        StubURLProtocol.register(host: siteHost, query: (name: "limit", value: "1000"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let teams = try await client.teams(league: soccerLeague())

        #expect(teams.count == 2)
        let bayern = try #require(teams.first)
        #expect(bayern.id == "espn:soccer/ger.1:132")
        #expect(bayern.name == "Bayern Munich")
        #expect(bayern.colorHex == "dc052d")
        #expect(bayern.logoURL == URL(string: "https://a/full.png"))
        #expect(bayern.darkLogoURL == URL(string: "https://a/dark.png"))
        #expect(teams[1].darkLogoURL == nil)
    }

    // MARK: - Standings

    @Test func `standings maps a soccer table row`() async throws {
        let body = """
        {"children": [{"name": "Bundesliga", "standings": {"entries": [
          {"team": {"id": "132", "displayName": "Bayern Munich", "abbreviation": "BAY"}, "stats": [
            {"name": "gamesPlayed", "abbreviation": "GP", "displayValue": "5", "value": 5},
            {"name": "wins", "abbreviation": "W", "displayValue": "4", "value": 4},
            {"name": "ties", "abbreviation": "D", "displayValue": "1", "value": 1},
            {"name": "losses", "abbreviation": "L", "displayValue": "0", "value": 0},
            {"name": "pointDifferential", "abbreviation": "GD", "displayValue": "+8", "value": 8},
            {"name": "points", "abbreviation": "PTS", "displayValue": "13", "value": 13},
            {"name": "rank", "abbreviation": "RK", "displayValue": "1", "value": 1}
          ]}
        ]}}]}
        """
        StubURLProtocol.register(host: webHost, pathSuffix: "/soccer/ger.1/standings", response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: soccerLeague())

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == .team)
        #expect(row.teamId == "132")
        #expect(row.name == "Bayern Munich")
        #expect(row.rank == 1)
        #expect(row.played == 5)
        #expect(row.wins == 4)
        #expect(row.draws == 1)
        #expect(row.losses == 0)
        #expect(row.goalDifference == 8)
        #expect(row.points == 13)
    }

    // MARK: - Summary (event detail)

    @Test func `summary maps key events, team stats and lineups`() async throws {
        let body = """
        {
          "boxscore": {"teams": [
            {"homeAway": "home", "team": {"id": "132"},
             "statistics": [{"name": "possessionPct", "label": "Possession", "displayValue": "60%", "value": 60}]},
            {"homeAway": "away", "team": {"id": "124"},
             "statistics": [{"name": "possessionPct", "label": "Possession", "displayValue": "40%", "value": 40}]}
          ]},
          "rosters": [
            {"homeAway": "home", "formation": "4-2-3-1", "team": {"id": "132"}, "roster": [
              {"athlete": {"displayName": "Manuel Neuer"}, "jersey": "1", "position": {"abbreviation": "G"}, "starter": true},
              {"athlete": {"displayName": "Bench Player"}, "jersey": "20", "position": {"abbreviation": "M"}, "starter": false}
            ]}
          ],
          "keyEvents": [
            {"type": {"text": "Goal"}, "clock": {"displayValue": "23'"}, "team": {"id": "132"},
             "scoringPlay": true, "athletesInvolved": [{"displayName": "Harry Kane"}]},
            {"type": {"text": "Yellow Card"}, "clock": {"displayValue": "41'"}, "team": {"id": "124"},
             "yellowCard": true, "athletesInvolved": [{"displayName": "Julian Brandt"}]}
          ]
        }
        """
        StubURLProtocol.register(host: siteHost, query: (name: "event", value: "401773"), response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let detail = try #require(try await client.eventDetail(league: soccerLeague(), eventId: "401773"))

        #expect(detail.keyEvents.count == 2)
        let goal = try #require(detail.keyEvents.first)
        #expect(goal.isGoal == true)
        #expect(goal.clock == "23'")
        #expect(goal.participants == ["Harry Kane"])
        #expect(goal.teamId == "132")
        #expect(detail.keyEvents[1].isCard == true)

        #expect(detail.teamStats.count == 1)
        let stat = try #require(detail.teamStats.first)
        #expect(stat.name == "Possession")
        #expect(stat.homeValue == 60)
        #expect(stat.awayValue == 40)
        #expect(stat.homeDisplay == "60%")

        #expect(detail.lineups.count == 1)
        let lineup = try #require(detail.lineups.first)
        #expect(lineup.formation == "4-2-3-1")
        #expect(lineup.starters.count == 1)
        #expect(lineup.starters.first?.name == "Manuel Neuer")
        #expect(lineup.starters.first?.jersey == "1")
        #expect(lineup.starters.first?.position == "G")
    }

    // MARK: - F1 sessions

    @Test func `f1 scoreboard maps the weekend sessions`() async throws {
        let body = """
        {"leagues": [{"name": "Formula 1", "abbreviation": "F1"}],
         "events": [{"id": "600", "date": "2026-05-24T13:00Z", "name": "Monaco Grand Prix", "shortName": "Monaco GP",
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

    @Test func `a single standings group carries no group name`() async throws {
        let body = """
        {"children": [{"name": "Bundesliga", "standings": {"entries": [
          {"team": {"id": "132", "displayName": "Bayern Munich"}, "stats": [{"name": "rank", "value": 1}]}
        ]}}]}
        """
        StubURLProtocol.register(host: webHost, pathSuffix: "/soccer/eng.1/standings", response: .init(body: body))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: league(sport: "soccer", slug: "eng.1"))

        #expect(rows.first?.group == nil)
        #expect(SportsStandingRow.grouped(rows).count == 1)
    }

    @Test func `grouping an ungrouped cache still separates drivers from constructors`() {
        let rows = [
            SportsStandingRow(id: "d1", kind: .driver, name: "Driver A", rank: 1, points: 10),
            SportsStandingRow(id: "d2", kind: .driver, name: "Driver B", rank: 2, points: 8),
            SportsStandingRow(id: "c1", kind: .constructor, name: "Team A", rank: 1, points: 18)
        ]
        let groups = SportsStandingRow.grouped(rows)
        #expect(groups.map(\.kind) == [.driver, .constructor])
        #expect(groups.map(\.rows.count) == [2, 1])
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

    // MARK: - Degrade to empty

    @Test func `garbage scoreboard JSON yields an empty list, not a throw`() async throws {
        StubURLProtocol.register(host: siteHost, query: (name: "dates", value: "209912"), response: .init(body: "not json {{"))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let fixtures = try await client.fixtures(league: soccerLeague(), month: DateComponents(year: 2099, month: 12))
        #expect(fixtures.isEmpty)
    }

    @Test func `garbage summary JSON yields nil, not a throw`() async throws {
        StubURLProtocol.register(host: siteHost, query: (name: "event", value: "999"), response: .init(body: "<html>nope</html>"))
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let detail = try await client.eventDetail(league: soccerLeague(), eventId: "999")
        #expect(detail == nil)
    }

    @Test func `non-2xx status yields an empty list`() async throws {
        StubURLProtocol.register(
            host: webHost,
            pathSuffix: "/soccer/esp.1/standings",
            response: .init(status: 404, body: "")
        )
        // A dedicated league so the 404 route can't clash with the success case.
        let league = SportsLeague(sport: "soccer", slug: "esp.1", name: "LaLiga", abbreviation: "LAL", region: .spain)
        let client = ESPNClient(session: StubURLProtocol.makeSession())

        let rows = try await client.standings(league: league)
        #expect(rows.isEmpty)
    }

    @Test func `always configured`() {
        #expect(ESPNClient().isConfigured == true)
    }
}
