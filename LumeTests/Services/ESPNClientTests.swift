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
        #expect(fixture.leagueName == "German Bundesliga")
        #expect(fixture.leagueAbbreviation == "GER")
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
         "events": [{"id": "600", "date": "2026-05-24T13:00Z", "name": "Monaco Grand Prix",
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
