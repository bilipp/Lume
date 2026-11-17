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

    private func game(id: String, daysAgo: Int = 0, year: Int = 2026, week: Int = 10, startDate: Date? = nil) -> SportsReplayGame {
        let league = "espn:football/nfl"
        let date = startDate ?? now.addingTimeInterval(-Double(daysAgo) * 86400)
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

    @Test func `a weekday search uses the calendar's own names and the local game day`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let thursday = try #require(ESPNClient.parseDate("2026-11-12T19:00:00Z"))
        let games = [game(id: "thursday", startDate: thursday), game(id: "friday", startDate: thursday.addingTimeInterval(86400))]
        let filter = SportsReplayFilter(range: .season, query: calendar.weekdaySymbols[4])
        #expect(filter.apply(games, now: now, calendar: calendar).map(\.fixture.id) == ["thursday"])
        calendar.timeZone = TimeZone(secondsFromGMT: 14 * 3600)!
        #expect(filter.apply(games, now: now, calendar: calendar).isEmpty)
    }

    @Test func `search combines league and week labels`() {
        let games = [game(id: "ten"), game(id: "nine", week: 9)]
        #expect(SportsReplayFilter(query: "NFL Week 10").apply(games, now: now).map(\.fixture.id) == ["ten"])
        #expect(SportsReplayFilter(query: "unrelated").apply(games, now: now).isEmpty)
    }

    @Test func `files without a fixture obey dates and search and drop out of filters they cannot answer`() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let recent = SportsLibraryReplay(id: "recent", isEpisode: true, title: "Lions at Patriots", source: "NFL", day: now.addingTimeInterval(-86400), progress: 0)
        let old = SportsLibraryReplay(id: "old", isEpisode: true, title: "Bears at Packers", source: "NFL", day: now.addingTimeInterval(-90 * 86400), progress: 0)
        let undated = SportsLibraryReplay(id: "undated", isEpisode: true, title: "Lions classic", source: "NFL", day: nil, progress: 0)
        let all = [recent, old, undated]
        #expect(SportsReplayFilter(range: .recent).apply(all, now: now).map(\.id) == ["recent"])
        #expect(SportsReplayFilter(range: .season).apply(all, now: now).map(\.id) == ["recent", "old", "undated"])
        #expect(SportsReplayFilter(range: .season, query: "lions").apply(all, now: now).map(\.id) == ["recent", "undated"])
        #expect(SportsReplayFilter(range: .season, myTeams: true).apply(all, now: now).isEmpty)
        #expect(SportsReplayFilter(range: .season, week: 10).apply(all, now: now).isEmpty)
    }

    /// A source's air date is a calendar day. West of Greenwich, reading its
    /// UTC midnight in local time showed and filtered the day before.
    @Test func `an air date keeps its calendar day in a negative utc offset`() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = try #require(TimeZone(secondsFromGMT: -5 * 3600))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let day = try #require(utc.date(from: DateComponents(year: 2026, month: 8, day: 30)))
        let file = SportsLibraryReplay(id: "lynx", isEpisode: true, title: "Lynx at Dream", source: "Jellyfin", day: day, progress: 0)
        #expect(file.dayLabel?.contains("30") == true)
        #expect(file.dayLabel?.contains("29") == false)
        #expect(try eastern.component(.day, from: #require(file.day(in: eastern))) == 30)

        func chosen(_ dayOfMonth: Int) throws -> SportsReplayFilter {
            let date = try #require(eastern.date(from: DateComponents(year: 2026, month: 8, day: dayOfMonth, hour: 12)))
            return SportsReplayFilter(range: .custom, custom: date ... date)
        }
        #expect(try chosen(30).apply([file], calendar: eastern).map(\.id) == ["lynx"])
        #expect(try chosen(29).apply([file], calendar: eastern).isEmpty)
        #expect(SportsReplayLibrary.months(of: [file]).contains { $0.year == 2026 && $0.month == 8 })
    }
}
