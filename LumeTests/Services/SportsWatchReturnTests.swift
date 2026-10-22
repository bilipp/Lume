//
//  SportsWatchReturnTests.swift
//  LumeTests
//
//  Covers where Back from a Sports player lands: which sheet reopens, which
//  copy of the fixture it reopens with, and which channel it marks.
//

import Foundation
@testable import Lume
import Testing

private func makeFixture(id: String = "1", state: SportsFixtureState) -> SportsFixture {
    SportsFixture(
        id: id,
        leagueId: "espn:soccer/ger.1",
        leagueName: "Bundesliga",
        leagueAbbreviation: "BUND",
        startDate: Date(timeIntervalSince1970: 1_780_000_000),
        status: SportsFixtureStatus(state: state)
    )
}

private func makeChannel(_ id: String) -> ResolvedChannel {
    ResolvedChannel(
        stream: ResolvedStreamSummary(id: id, name: "DAZN \(id)", streamIcon: nil, epgChannelId: nil),
        playlistID: UUID(),
        matchedTitle: nil,
        matchedStart: nil,
        score: 1,
        source: .channelName,
        isConfident: false
    )
}

@MainActor
struct SportsWatchReturnTests {
    @Test func `a press with no sheet up has nothing to return to`() {
        #expect(SportsWatchReturn(channel: makeChannel("a"), detail: nil, picker: nil) == nil)
    }

    @Test func `the sheet that was up is the one that reopens`() throws {
        let fixture = makeFixture(state: .inProgress)
        let fromDetail = try #require(SportsWatchReturn(channel: makeChannel("a"), detail: fixture, picker: nil))
        let fromPicker = try #require(SportsWatchReturn(channel: makeChannel("a"), detail: nil, picker: fixture))
        #expect(fromDetail.card == .detail)
        #expect(fromPicker.card == .picker)
        #expect(fromDetail.channelID == "a")
    }

    @Test func `a game that ended meanwhile reopens as ended`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsStore(cache: SportsCacheStore(directory: dir))
        let live = makeFixture(state: .inProgress)
        let watchReturn = try #require(SportsWatchReturn(channel: makeChannel("a"), detail: live, picker: nil))

        #expect(watchReturn.currentFixture(in: store).status.state == .inProgress)

        store.update(SportsLeagueSnapshot(fixtures: [makeFixture(state: .final)]), for: live.leagueId)
        #expect(watchReturn.currentFixture(in: store).status.state == .final)
    }

    @Test func `marks the channel surfed onto when it carries the game`() throws {
        let channels = ["a", "b", "c"].map(makeChannel)
        let watchReturn = try #require(SportsWatchReturn(channel: channels[0], detail: makeFixture(state: .inProgress), picker: nil))

        #expect(watchReturn.channelToMark(among: channels, playing: "c") == "c")
        #expect(watchReturn.channelToMark(among: channels, playing: "elsewhere") == "a")
        #expect(watchReturn.channelToMark(among: channels, playing: nil) == "a")
    }
}
