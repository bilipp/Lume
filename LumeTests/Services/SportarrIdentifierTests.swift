//
//  SportarrIdentifierTests.swift
//  LumeTests
//
//  Public ID carriers are trusted; ordinary TVDB numbers and matchup titles
//  cannot turn an unrelated movie or episode into a sports file.
//

import Foundation
@testable import Lume
import Testing

struct SportarrIdentifierTests {
    @Test func `provider event wins over a conflicting alias and filename`() {
        let id = SportarrIdentifier.eventID(providerIDs: ["sportarr": "ev-123456", "Tvdb": "1000654321"], path: "Game {sportarr-ev-987654}.mkv")
        #expect(id == "ev-123456")
    }

    @Test func `aliases use the frozen event and league namespaces`() {
        #expect(SportarrIdentifier.eventID(providerIDs: ["Tvdb": "1000000042"], path: nil) == "ev-000042")
        #expect(SportarrIdentifier.leagueID(providerIDs: ["TVDB": "900000032"]) == "lg-000032")
        #expect(SportarrIdentifier.leagueID(providerIDs: ["Tvdb": "1000000000"]) == nil)
        #expect(SportarrIdentifier.eventID(providerIDs: ["Tvdb": "900000032"], path: nil) == nil)
        #expect(SportarrIdentifier.eventID(providerIDs: ["Tvdb": "74124"], path: nil) == nil)
        #expect(SportarrIdentifier.eventID(providerIDs: ["Tmdb": "1000000042"], path: nil) == nil)
    }

    @Test(arguments: [
        "Game {sportarr-ev-123456}.mkv", "Game {EV.123456}.mp4", "Game SPORTARR EV 123456.mkv",
        "Game sportarr_ev_123456.mkv", "Game ev-123456.mp4", "Game%20%7Bsportarr-ev-123456%7D.mkv"
    ])
    func `filename grammar accepts documented carriers`(path: String) {
        #expect(SportarrIdentifier.eventID(providerIDs: nil, path: path) == "ev-123456")
    }

    @Test(arguments: ["Lions at Patriots.mkv", "Sports/Game 2026.mkv", "Game ev-2026.mkv", "Game ev 123456.mkv", "Game ev123456.mkv"])
    func `titles years and unbranded loose tokens stay untouched`(path: String) {
        #expect(SportarrIdentifier.eventID(providerIDs: nil, path: path) == nil)
    }

    @Test func `multiple event identities in one path are not guessed`() {
        #expect(SportarrIdentifier.eventID(providerIDs: nil, path: "/{ev-123456}/Game {ev-654321}.mkv") == nil)
    }

    @Test func `date agreement uses calendar days across a night game`() throws {
        let json = #"{"id":"ev-123456","scheduled_start_local":"2026-11-13T01:15:00+00:00","broadcast_date":"2026-11-12"}"#
        let metadata = try JSONDecoder().decode(SportarrEpisode.self, from: Data(json.utf8))
        #expect(metadata.agrees(with: ESPNClient.parseDate("2026-11-14T23:00:00Z")))
        #expect(!metadata.agrees(with: ESPNClient.parseDate("2026-11-16T00:00:00Z")))
        #expect(metadata.agrees(with: nil))
    }
}
