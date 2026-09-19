//
//  SportsCatalogTests.swift
//  LumeTests
//
//  The curated league catalogue and per-region default follows are pure static
//  data, so these tests need no container or network.
//

import Foundation
@testable import Lume
import Testing

struct SportsCatalogTests {
    private func id(_ sport: String, _ slug: String) -> String {
        SportsLeague.makeID(sport: sport, slug: slug)
    }

    @Test func `league ids are provider-prefixed`() {
        let bundesliga = SportsCatalog.league(sport: "soccer", slug: "ger.1")
        #expect(bundesliga?.id == "espn:soccer/ger.1")
        #expect(SportsCatalog.league(id: "espn:soccer/ger.1")?.slug == "ger.1")
    }

    @Test func `catalog league ids are unique`() {
        let ids = SportsCatalog.leagues.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func `regionPreFollows Germany leads with Bundesliga then UCL`() {
        let follows = SportsCatalog.regionPreFollows(for: Locale.Region("DE"))
        #expect(follows == [id("soccer", "ger.1"), id("soccer", "uefa.champions")])
    }

    @Test func `regionPreFollows US returns the four US leagues`() {
        let follows = SportsCatalog.regionPreFollows(for: Locale.Region("US"))
        #expect(follows == [
            id("football", "nfl"),
            id("basketball", "nba"),
            id("baseball", "mlb"),
            id("hockey", "nhl")
        ])
    }

    @Test func `regionPreFollows Spain leads with LaLiga`() {
        let follows = SportsCatalog.regionPreFollows(for: Locale.Region("ES"))
        #expect(follows.first == id("soccer", "esp.1"))
        #expect(follows.contains(id("soccer", "uefa.champions")))
    }

    @Test func `regionPreFollows falls back for unknown region`() {
        let unknown = SportsCatalog.regionPreFollows(for: Locale.Region("ZZ"))
        let none = SportsCatalog.regionPreFollows(for: nil)
        let expected = [id("soccer", "uefa.champions"), id("soccer", "eng.1")]
        #expect(unknown == expected)
        #expect(none == expected)
    }

    @Test func `every pre-follow id resolves to a catalog league`() {
        let regions: [Locale.Region?] = [
            Locale.Region("DE"), Locale.Region("GB"), Locale.Region("US"),
            Locale.Region("ES"), Locale.Region("IT"), Locale.Region("FR"),
            Locale.Region("PT"), Locale.Region("BR"), Locale.Region("JP"), nil
        ]
        for region in regions {
            for leagueID in SportsCatalog.regionPreFollows(for: region) {
                #expect(SportsCatalog.league(id: leagueID) != nil)
            }
        }
    }
}
