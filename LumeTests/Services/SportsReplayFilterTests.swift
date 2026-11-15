//
//  SportsReplayFilterTests.swift
//  LumeTests
//
//  Date, team and season journeys use one rule set on every platform.
//

import Foundation
@testable import Lume
import Testing

struct SportsReplayFilterTests {
    private let now = Date(timeIntervalSince1970: 1_794_765_600)

    private func game(id: String, daysAgo: Int = 0, year: Int = 2026, week: Int = 10) -> SportsReplayGame {
        let league = "espn:football/nfl"
        let date = now.addingTimeInterval(-Double(daysAgo) * 86400)
        let team = SportsTeam(leagueId: league, teamId: "lions", name: "Detroit Lions", shortName: "Lions", abbreviation: "DET")
        let fixture = SportsFixture(
            id: id, leagueId: league, leagueName: "NFL", leagueAbbreviation: "NFL", startDate: date,
            status: SportsFixtureStatus(state: .final), home: SportsCompetitor(team: team),
            seasonYear: year, seasonPhase: "Regular Season", week: week, weekLabel: "Week \(week)"
        )
        let recording = ServerRecording(id: RecordingID(rawValue: id), title: "Football", start: date, end: date.addingTimeInterval(7200), status: .completed, createdAt: date)
        return SportsReplayGame(fixture: fixture, recordings: [recording])
    }

    @Test func `recent expands without changing calendar scope`() {
        let games = [game(id: "today"), game(id: "older", daysAgo: 20)]
        #expect(SportsReplayFilter().apply(games, now: now).map(\.fixture.id) == ["today"])
        #expect(SportsReplayFilter(recentDays: 28).apply(games, now: now).count == 2)
    }

    @Test func `this season excludes older seasons but permits an explicit selection`() {
        let games = [game(id: "current"), game(id: "old", daysAgo: 365, year: 2025)]
        #expect(SportsReplayFilter(range: .season).apply(games, now: now).map(\.fixture.id) == ["current"])
        #expect(SportsReplayFilter(range: .season, season: 2025).apply(games, now: now).map(\.fixture.id) == ["old"])
    }

    @Test func `my teams and week filters combine without changing all scope`() {
        let games = [game(id: "ten"), game(id: "nine", daysAgo: 7, week: 9)]
        var filter = SportsReplayFilter(myTeams: true)
        #expect(filter.apply(games, now: now).isEmpty)
        filter.followedTeamIDs = ["espn:football/nfl:lions"]
        filter.week = 9
        #expect(filter.apply(games, now: now).map(\.fixture.id) == ["nine"])
        filter.myTeams = false
        filter.followedTeamIDs = []
        #expect(filter.apply(games, now: now).count == 1)
    }

    @Test func `search combines league and week labels`() {
        let games = [game(id: "ten"), game(id: "nine", week: 9)]
        #expect(SportsReplayFilter(query: "NFL Week 10").apply(games, now: now).map(\.fixture.id) == ["ten"])
        #expect(SportsReplayFilter(query: "unrelated").apply(games, now: now).isEmpty)
    }
}
