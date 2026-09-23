//
//  ESPNClientTennisTests.swift
//  LumeTests
//
//  Tennis's own scoreboard shape: tournaments whose matches sit under
//  `groupings`, athletes with per-set `linescores`, and the world ranking that
//  stands in for both a tour's teams and its table. Split from `ESPNClientTests`
//  to keep that suite under the length cap.
//

import Foundation
@testable import Lume
import Testing

struct ESPNClientTennisTests {
    private func league(sport: String, slug: String) -> SportsLeague {
        SportsLeague(sport: sport, slug: slug, name: slug, abbreviation: slug.uppercased(), region: .tennis)
    }

    /// Shaped like ESPN's WTA scoreboard: one event per tournament, its matches
    /// under `groupings`, athletes with flags and per-set `linescores` — and, at a
    /// combined event, the men's draw too.
    private static let tennisScoreboardJSON = """
    {"events": [{"id": "1022-2026", "date": "2026-09-20T04:00Z", "name": "Eupago Porto Open", "shortName": "Porto",
      "venue": {"displayName": "Porto, Portugal"},
      "status": {"type": {"name": "STATUS_FINAL", "state": "post", "completed": true}},
      "groupings": [
        {"grouping": {"slug": "womens-singles"}, "competitions": [
          {"id": "183949", "date": "2026-09-23T14:30Z", "timeValid": true, "round": {"displayName": "Round 2"},
           "venue": {"fullName": "Porto, Portugal", "court": "Centre Court"},
           "status": {"period": 2, "type": {"name": "STATUS_IN_PROGRESS", "state": "in", "completed": false,
                                            "detail": "2nd Set", "shortDetail": "2nd"}},
           "competitors": [
             {"id": "4438", "homeAway": "away", "type": "athlete",
              "linescores": [{"value": 3.0, "winner": false}, {"value": 0.0}],
              "athlete": {"displayName": "Kajsa Rinaldo Persson", "shortName": "K. Rinaldo Persson",
                          "flag": {"href": "https://a.espncdn.com/i/teamlogos/countries/500/swe.png"}}},
             {"id": "10501", "homeAway": "home", "type": "athlete",
              "linescores": [{"value": 6.0, "winner": true}, {"value": 3.0}],
              "athlete": {"displayName": "Maria Timofeeva", "shortName": "M. Timofeeva",
                          "flag": {"href": "https://a.espncdn.com/i/teamlogos/countries/500/uzb.png"}}}
           ]},
          {"id": "183950", "date": "2026-09-22T12:00Z", "round": {"displayName": "Quarterfinal"},
           "status": {"period": 2, "type": {"name": "STATUS_FINAL", "state": "post", "completed": true}},
           "competitors": [
             {"id": "1", "homeAway": "home", "winner": true,
              "linescores": [{"value": 7.0, "tiebreak": 7, "winner": true}, {"value": 6.0, "winner": true}],
              "athlete": {"displayName": "Ana Home", "shortName": "A. Home"}},
             {"id": "2", "homeAway": "away", "winner": false,
              "linescores": [{"value": 6.0, "tiebreak": 5, "winner": false}, {"value": 2.0, "winner": false}],
              "athlete": {"displayName": "Bea Away", "shortName": "B. Away"}}
           ]},
          {"id": "183951", "date": "2026-09-19T10:00Z", "round": {"displayName": "Qualifying 1st Round"},
           "status": {"type": {"state": "post", "completed": true}},
           "competitors": [
             {"id": "3", "homeAway": "home", "athlete": {"displayName": "Q One"}},
             {"id": "4", "homeAway": "away", "athlete": {"displayName": "Q Two"}}
           ]},
          {"id": "183952", "date": "2026-09-27T04:00Z", "timeValid": false, "round": {"displayName": "Final"},
           "status": {"type": {"state": "pre"}},
           "competitors": [
             {"id": "-3", "homeAway": "home", "athlete": {"displayName": "TBD"}},
             {"id": "1", "homeAway": "away", "athlete": {"displayName": "Ana Home"}}
           ]},
          {"id": "183953", "date": "2026-09-24T04:00Z", "timeValid": false, "round": {"displayName": "Semifinal"},
           "status": {"type": {"state": "pre"}},
           "competitors": [
             {"id": "1", "homeAway": "home", "athlete": {"displayName": "Ana Home"}},
             {"id": "5", "homeAway": "away", "athlete": {"displayName": "Cleo Five"}}
           ]}
        ]},
        {"grouping": {"slug": "womens-doubles"}, "competitions": [
          {"id": "183960", "date": "2026-09-23T10:00Z", "status": {"type": {"state": "pre"}}, "competitors": []}
        ]},
        {"grouping": {"slug": "mens-singles"}, "competitions": [
          {"id": "183970", "date": "2026-09-23T10:00Z", "status": {"type": {"state": "pre"}},
           "competitors": [
             {"id": "8", "homeAway": "home", "athlete": {"displayName": "Man One"}},
             {"id": "9", "homeAway": "away", "athlete": {"displayName": "Man Two"}}
           ]}
        ]}
      ]}]}
    """

    @Test func `a tennis tournament becomes one fixture per main-draw singles match of the tour`() throws {
        let scoreboard = try JSONDecoder().decode(ESPNScoreboard.self, from: Data(Self.tennisScoreboardJSON.utf8))
        let fixtures = ESPNClient.mapScoreboard(scoreboard, league: league(sport: "tennis", slug: "wta"))

        // Qualifying, TBD slots, doubles and the men's draw are left out.
        #expect(fixtures.map(\.id).sorted() == ["183949", "183950", "183953"])

        let live = try #require(fixtures.first { $0.id == "183949" })
        #expect(live.status.state == .inProgress)
        #expect(live.name == "Eupago Porto Open")
        #expect(live.round == "Round 2")
        #expect(live.venue == "Porto, Portugal")
        #expect(live.home?.team.name == "Maria Timofeeva")
        #expect(live.home?.team.shortName == "M. Timofeeva")
        #expect(live.home?.team.id == "espn:tennis/wta:10501")
        #expect(live.home?.team.logoURL?.absoluteString == "https://a.espncdn.com/i/teamlogos/countries/500/uzb.png")
        #expect(live.home?.score == 1)
        #expect(live.away?.score == 0)
        #expect(live.home?.displayScore == "6 3")
        #expect(live.away?.displayScore == "3 0")
        #expect(live.scoreLine == "1 – 0")
        #expect(live.setsLine == "6-3 3-0")
        #expect(live.hasSetScores)
        #expect(!live.hasTextScores)
        #expect(live.periodFamily == .sets)
        #expect(live.startTimeIsTentative == nil)

        let final = try #require(fixtures.first { $0.id == "183950" })
        #expect(final.home?.isWinner == true)
        #expect(final.scoreLine == "2 – 0")
        #expect(final.setsLine == "7-6(5) 6-2")

        let unscheduled = try #require(fixtures.first { $0.id == "183953" })
        #expect(unscheduled.startTimeIsTentative == true)
        #expect(unscheduled.home?.displayScore == "–")
    }

    @Test func `a tennis tour's ranking is both its players and its standings`() throws {
        let body = """
        {"rankings": [{"name": "ATP", "ranks": [
          {"current": 1, "previous": 1, "points": 11500.0, "trend": "-",
           "athlete": {"id": "3623", "displayName": "Jannik Sinner", "shortname": "J. Sinner",
                       "flag": "https://a.espncdn.com/i/teamlogos/countries/500/ita.png", "flagAltText": "Italy"}},
          {"current": 2, "previous": 3, "points": 9590.0,
           "athlete": {"id": "3782", "displayName": "Carlos Alcaraz", "shortname": "C. Alcaraz"}}
        ]}]}
        """
        let response = try JSONDecoder().decode(ESPNRankingsResponse.self, from: Data(body.utf8))
        let players = ESPNClient.mapRankings(response, leagueId: "espn:tennis/atp")
        #expect(players.count == 2)
        let first = try #require(players.first)
        #expect(first.team.id == "espn:tennis/atp:3623")
        #expect(first.team.shortName == "J. Sinner")
        #expect(first.team.logoURL?.absoluteString == "https://a.espncdn.com/i/teamlogos/countries/500/ita.png")
        #expect(first.row.kind == .player)
        #expect(first.row.teamId == "3623")
        #expect(first.row.rank == 1)
        #expect(first.row.points == 11500)
        #expect(first.row.extra["country"] == "Italy")
        #expect(players[1].row.extra["previous"] == "3")
    }

    @Test func `a tennis match has no summary feed, so detail is nil without a request`() async throws {
        let detail = try await ESPNClient().eventDetail(league: league(sport: "tennis", slug: "atp"), eventId: "183949")
        #expect(detail == nil)
    }
}
