//
//  SportsReplayLibraryTests.swift
//  LumeTests
//
//  A wrong sports association is worse than leaving a recording in Recordings.
//  Exercise ambiguity, full windows and late partials without a live service.
//

import Foundation
@testable import Lume
import Testing

struct SportsReplayLibraryTests {
    private let kickoff = Date(timeIntervalSince1970: 1_750_000_000)
    private let aliases = SportsTeamAliases(rawEntries: [:])

    private func fixture(id: String = "game", offset: TimeInterval = 0) -> SportsFixture {
        let league = "espn:football/nfl"
        return SportsFixture(
            id: id, leagueId: league, leagueName: "NFL", leagueAbbreviation: "NFL",
            startDate: kickoff.addingTimeInterval(offset), status: SportsFixtureStatus(state: .final),
            home: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "1", name: "Detroit Lions", shortName: "Lions", abbreviation: "DET")),
            away: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "2", name: "New England Patriots", shortName: "Patriots", abbreviation: "NE"))
        )
    }

    private func recording(
        title: String = "Detroit Lions versus New England Patriots",
        offset: TimeInterval = -600,
        programmeStart: Date? = nil,
        status: ServerRecordingStatus = .completed
    ) -> ServerRecording {
        ServerRecording(
            id: RecordingID(rawValue: "1"), title: title,
            sourceRef: "11111111-1111-1111-1111-111111111111:live:channel",
            start: kickoff.addingTimeInterval(offset), end: kickoff.addingTimeInterval(10800),
            status: status, createdAt: kickoff, programmeStart: programmeStart
        )
    }

    @Test func `only one matching fixture creates a game`() {
        let recording = recording()
        #expect(SportsReplayLibrary.games(recordings: [recording], fixtures: [fixture()], aliases: aliases).count == 1)
        #expect(SportsReplayLibrary.games(recordings: [recording], fixtures: [fixture(), fixture(id: "other", offset: 3600)], aliases: aliases).isEmpty)
    }

    @Test func `full window excludes a matching game after the capture`() {
        #expect(SportsReplayLibrary.games(recordings: [recording()], fixtures: [fixture(offset: 20000)], aliases: aliases).isEmpty)
    }

    @Test func `late partial requires original programme evidence`() {
        #expect(SportsReplayLibrary.games(recordings: [recording(offset: 9000)], fixtures: [fixture()], aliases: aliases).isEmpty)
        let partial = recording(offset: 9000, programmeStart: kickoff)
        #expect(SportsReplayLibrary.games(recordings: [partial], fixtures: [fixture()], aliases: aliases).count == 1)
    }

    @Test func `scheduled and failed recordings never become replays`() {
        for status: ServerRecordingStatus in [.scheduled, .failed, .cancelled, .unknown("future")] {
            #expect(SportsReplayLibrary.games(recordings: [recording(status: status)], fixtures: [fixture()], aliases: aliases).isEmpty)
        }
    }

    @Test func `channel fallback needs one game and no team evidence`() throws {
        let game = fixture()
        let recording = recording(title: "Football")
        let channels = try [game.leagueId + ":" + game.id: Set([#require(recording.sourceRef)])]
        #expect(SportsReplayLibrary.games(recordings: [recording], fixtures: [game], channels: channels, aliases: aliases).count == 1)
        #expect(SportsReplayLibrary.games(recordings: [self.recording(title: "Lions highlight show")], fixtures: [game], channels: channels, aliases: aliases).isEmpty)
        #expect(SportsReplayLibrary.games(recordings: [self.recording(title: "Football", offset: 9000, programmeStart: kickoff)], fixtures: [game], channels: channels, aliases: aliases).isEmpty)
    }

    @Test func `channel fallback skips a rebroadcast of another game in the league`() throws {
        let game = fixture()
        let league = game.leagueId
        let earlier = SportsFixture(
            id: "earlier", leagueId: league, leagueName: "NFL", leagueAbbreviation: "NFL",
            startDate: kickoff.addingTimeInterval(-7 * 86400), status: SportsFixtureStatus(state: .final),
            home: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "3", name: "Chicago Bears", shortName: "Bears", abbreviation: "CHI")),
            away: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "4", name: "Green Bay Packers", shortName: "Packers", abbreviation: "GB"))
        )
        let rebroadcast = recording(title: "Bears at Packers (encore)")
        let channels = try [league + ":" + game.id: Set([#require(rebroadcast.sourceRef)])]
        #expect(SportsReplayLibrary.games(recordings: [rebroadcast], fixtures: [game, earlier], channels: channels, aliases: aliases).isEmpty)
    }

    @Test func `multiple recordings are versions and fixtures are deduplicated`() {
        var second = recording()
        second.id = RecordingID(rawValue: "2")
        let games = SportsReplayLibrary.games(recordings: [recording(), second], fixtures: [fixture(), fixture()], aliases: aliases)
        #expect(games.count == 1)
        #expect(games.first?.recordings.count == 2)
    }

    private func file(_ id: String, title: String = "Lions at Patriots", dayOffset: TimeInterval = 0) -> SportsLibraryReplay {
        // Sources report the air date as a UTC calendar day.
        let day = Date(timeIntervalSince1970: (kickoff.timeIntervalSince1970 / 86400).rounded(.down) * 86400 + dayOffset)
        return SportsLibraryReplay(id: id, isEpisode: true, title: title, source: "NFL", day: day, progress: 0)
    }

    @Test func `a library file joins the game its title and air date name`() {
        let games = SportsReplayLibrary.games(recordings: [recording()], library: [file("full"), file("condensed")], fixtures: [fixture()], aliases: aliases)
        #expect(games.count == 1)
        #expect(games.first?.versions.map(\.id) == ["1", "full", "condensed"])
        // A night game is filed under the day on either side of its kickoff.
        #expect(SportsReplayLibrary.games(recordings: [], library: [file("next", dayOffset: 86400)], fixtures: [fixture()], aliases: aliases).count == 1)
    }

    @Test func `an edition whose title names no team joins its event's game`() {
        var full = file("full")
        var condensed = file("condensed", title: "Condensed Game")
        var stray = file("stray", title: "Condensed Game")
        full.event = "sportarr://ev-1"
        condensed.event = "sportarr://ev-1"
        stray.event = "sportarr://ev-2"
        let games = SportsReplayLibrary.games(recordings: [], library: [full, condensed, stray], fixtures: [fixture()], aliases: aliases)
        #expect(games.first?.library.map(\.id) == ["full", "condensed"])
    }

    @MainActor @Test func `a sports episode stands alone only while library replays are on`() {
        let league = Series(id: "s", seriesId: 1, name: "NFL")
        league.sportsRef = "sportarr://lg-000032"
        let game = Episode(id: "e", episodeId: "e", title: "Lions at Patriots", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        game.series = league
        let ordinary = Episode(id: "o", episodeId: "o", title: "Pilot", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        #expect(game.isStandaloneReplay(replaysOn: true))
        #expect(!game.isStandaloneReplay(replaysOn: false))
        #expect(!ordinary.isStandaloneReplay(replaysOn: true))
    }

    @Test func `a library asks for the schedule months its games can fall in`() {
        // 15 June stays in June; 30 June can be a game played on 1 July.
        let months = SportsReplayLibrary.months(of: [file("mid"), file("last", dayOffset: 15 * 86400)])
        #expect(Set(months.map { [$0.year, $0.month] }) == [[2025, 6], [2025, 7]])
        #expect(SportsReplayLibrary.months(of: []).isEmpty)
    }

    /// A season's archive on one night: every file sees every fixture as a
    /// date candidate. Each must still find exactly its own game, and quickly
    /// enough that deriving the list is not a visible wait.
    @Test func `a full season of library files is matched exactly and promptly`() {
        let league = "espn:football/nfl"
        let fixtures = (0 ..< 215).map { index in
            SportsFixture(
                id: "game\(index)", leagueId: league, leagueName: "NFL", leagueAbbreviation: "NFL",
                startDate: kickoff.addingTimeInterval(TimeInterval(index)), status: SportsFixtureStatus(state: .final),
                home: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "h\(index)", name: "Homecity\(index)", shortName: "Homecity\(index)", abbreviation: "H")),
                away: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "a\(index)", name: "Awaytown\(index)", shortName: "Awaytown\(index)", abbreviation: "A"))
            )
        }
        let files = (0 ..< 215).map { file("file\($0)", title: "Awaytown\($0) at Homecity\($0)") }
        var games: [SportsReplayGame] = []
        let elapsed = ContinuousClock().measure {
            games = SportsReplayLibrary.games(recordings: [], library: files, fixtures: fixtures, aliases: aliases)
        }
        #expect(games.count == 215)
        #expect(games.allSatisfy { $0.library.count == 1 && $0.library[0].id == "file" + $0.fixture.id.dropFirst(4) })
        #expect(elapsed < .seconds(2))
    }

    @Test func `a library file is never attached by date alone or to an ambiguous game`() {
        let untitled = file("untitled", title: "Week 10")
        let undated = SportsLibraryReplay(id: "undated", isEpisode: true, title: "Lions at Patriots", source: "NFL", day: nil, progress: 0)
        let far = file("far", dayOffset: 4 * 86400)
        #expect(SportsReplayLibrary.games(recordings: [], library: [untitled, undated, far], fixtures: [fixture()], aliases: aliases).isEmpty)
        let rematch = [fixture(), fixture(id: "other", offset: 3600)]
        #expect(SportsReplayLibrary.games(recordings: [], library: [file("full")], fixtures: rematch, aliases: aliases).isEmpty)
    }

    @Test func `captured late partial matches the original NFL programme`() throws {
        struct Evidence: Decodable {
            let recordings: [DispatcharrRecording]
            let scoreboard: ESPNScoreboard
        }
        let url = repoRootURL(filePath: #filePath)
            .appendingPathComponent("LumeTests/Fixtures/SportsReplays/sports-replay-nfl-partial.json")
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: url))
        let now = try #require(ESPNClient.parseDate("2026-11-15T18:00:00Z"))
        let recordings = evidence.recordings.map {
            DispatcharrBackend.serverRecording($0, channelName: "Fixture TV", channelLogoURL: nil, now: now)
        }
        let league = try #require(SportsCatalog.league(id: "espn:football/nfl"))
        let fixtures = ESPNClient.mapScoreboard(evidence.scoreboard, league: league)
        let games = SportsReplayLibrary.games(recordings: recordings, fixtures: fixtures)
        #expect(games.count == 1)
        #expect(games.first?.fixture.id == "401873053")
        #expect(games.first?.recordings.first?.programmeStart == ESPNClient.parseDate("2026-11-15T14:30:00Z"))
    }
}
