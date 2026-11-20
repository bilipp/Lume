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
