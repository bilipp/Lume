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

    @Test func `league tokens come from provider ids aliases and folder paths`() {
        #expect(SportarrIdentifier.leagueID(providerIDs: ["Sportarr": "sportarr://lg-000032"]) == "lg-000032")
        #expect(SportarrIdentifier.leagueID(providerIDs: nil, path: "/Sports/NFL {sportarr-lg-000032}/Week 10/Game {sportarr-ev-123456}.mkv") == "lg-000032")
        #expect(SportarrIdentifier.leagueID(providerIDs: nil, path: "/Shows/Some League/S01E01.mkv") == nil)
    }

    @Test func `an event reference is told apart from a league reference`() {
        #expect(SportarrIdentifier.isEvent("sportarr://ev-1969704"))
        #expect(!SportarrIdentifier.isEvent("sportarr://lg-000032"))
        #expect(!SportarrIdentifier.isEvent(nil))
    }

    @Test func `evidence writes an observed miss clears and an unobserved response leaves the row alone`() {
        let stored = "sportarr://ev-123456"
        #expect(SportarrIdentifier.reference(.event, providerIDs: ["Sportarr": "ev-654321"], path: nil, observed: true, current: stored) == "sportarr://ev-654321")
        #expect(SportarrIdentifier.reference(.event, providerIDs: [:], path: nil, observed: true, current: stored) == nil)
        #expect(SportarrIdentifier.reference(.event, providerIDs: nil, path: nil, observed: false, current: stored) == stored)
    }

    @Test func `jellyfin compatible items classify from provider ids and never from tags or titles`() throws {
        let series = try item(#"{"Id":"s","Name":"NFL","Type":"Series","ProviderIds":{"Sportarr":"lg-000032","Tvdb":"900000032"}}"#)
        let episode = try item(#"{"Id":"e","Name":"Commanders at Giants","Type":"Episode","ProviderIds":{"Tvdb":"1001969836"}}"#)
        let tagged = try item(#"{"Id":"t","Name":"Commanders at Giants","Type":"Movie","ProviderIds":{},"Tags":["sports","sportarr"],"Genres":["Sports"]}"#)
        let bare = try item(#"{"Id":"b","Name":"Episode","Type":"Episode"}"#)
        #expect(series.sportsRef(.league, current: nil) == "sportarr://lg-000032")
        #expect(episode.sportsRef(.event, current: nil) == "sportarr://ev-1969836")
        #expect(tagged.sportsRef(.event, current: "sportarr://ev-123456") == nil)
        #expect(bare.sportsRef(.event, current: "sportarr://ev-123456") == "sportarr://ev-123456")
    }

    @Test func `plex items classify from the external guid array`() throws {
        let show = try plex(#"{"ratingKey":"1","Guid":[{"id":"sportarr://lg-000142"},{"id":"tvdb://900000142"}]}"#)
        let episode = try plex(#"{"ratingKey":"2","Guid":[{"id":"sportarr://ev-848683"}]}"#)
        let ordinary = try plex(#"{"ratingKey":"3","Guid":[{"id":"tmdb://675"},{"id":"tvdb://74124"}]}"#)
        let unfetched = try plex(#"{"ratingKey":"4"}"#)
        #expect(show.sportsRef(.league, current: nil) == "sportarr://lg-000142")
        #expect(episode.sportsRef(.event, current: nil) == "sportarr://ev-848683")
        #expect(ordinary.sportsRef(.event, current: "sportarr://ev-848683") == nil)
        #expect(unfetched.sportsRef(.event, current: "sportarr://ev-848683") == "sportarr://ev-848683")
    }

    @Test func `file sources classify from the entry url alone`() {
        let entry = M3UEntry(name: "Commanders at Giants", url: "https://dav.example.invalid/Sports/NFL%20%7Bsportarr-lg-000032%7D/Game%20%7Bsportarr-ev-1969836%7D.mkv")
        #expect(entry.sportsRef(.event) == "sportarr://ev-1969836")
        #expect(entry.sportsRef(.league) == "sportarr://lg-000032")
        #expect(M3UEntry(name: "Commanders at Giants", url: "https://dav.example.invalid/Sports/Game.mkv").sportsRef(.event) == nil)
    }

    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func plex(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }
}
