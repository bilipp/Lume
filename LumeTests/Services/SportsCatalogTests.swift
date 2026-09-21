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
        let codes = [
            "DE", "AT", "CH", "GB", "IE", "US", "CA", "ES", "IT", "FR", "NL", "PT", "BE", "TR", "GR", "DK", "NO",
            "SE", "RU", "MX", "BR", "AR", "CL", "CO", "PE", "UY", "PY", "EC", "BO", "VE", "AU", "NZ", "ZA", "SA",
            "JP", "CN", "KR"
        ]
        let regions: [Locale.Region?] = codes.map { Locale.Region($0) } + [nil]
        for region in regions {
            let follows = SportsCatalog.regionPreFollows(for: region)
            #expect(!follows.isEmpty)
            for leagueID in follows {
                #expect(SportsCatalog.league(id: leagueID) != nil, "\(String(describing: region)) → \(leagueID)")
            }
        }
    }

    @Test func `regionPreFollows Australia leads with the AFL and NRL`() {
        let follows = SportsCatalog.regionPreFollows(for: Locale.Region("AU"))
        #expect(follows.first == id("australian-football", "afl"))
        #expect(follows.contains(id("rugby-league", "3")))
    }

    // MARK: - Catalogue shape

    @Test func `every region section has at least one league`() {
        for region in SportsRegion.allCases {
            #expect(!SportsCatalog.leagues(in: region).isEmpty, "\(region)")
        }
    }

    @Test func `the catalogue spans football and the other sports`() {
        let sports = Set(SportsCatalog.leagues.map(\.sport))
        let expected = [
            "soccer", "football", "basketball", "hockey", "baseball", "rugby", "rugby-league",
            "australian-football", "lacrosse", "racing", "mma"
        ]
        for sport in expected {
            #expect(sports.contains(sport), "\(sport)")
        }
        #expect(SportsCatalog.leagues.count(where: { $0.sport == "soccer" }) >= 100)
        #expect(SportsCatalog.leagues.count >= 140)
    }

    @Test func `every league has a name and a short abbreviation`() {
        for league in SportsCatalog.leagues {
            #expect(!league.name.isEmpty, "\(league.id)")
            #expect(!league.abbreviation.isEmpty, "\(league.id)")
            #expect(league.abbreviation.count <= 12, "\(league.id)")
        }
    }

    // MARK: - Browse order

    @Test func `browse order lifts the home sections and keeps every region once`() {
        let base = SportsCatalog.regionsInOrder
        #expect(base.first == .germany)
        #expect(Set(base).count == base.count)
        #expect(Set(base) == Set(SportsRegion.allCases))

        let unitedStates = SportsCatalog.browseRegions(for: Locale.Region("US"))
        #expect(Array(unitedStates.prefix(4)) == [.americanFootball, .basketball, .baseball, .iceHockey])
        #expect(Set(unitedStates) == Set(base))
        #expect(unitedStates.count == base.count)

        let britain = SportsCatalog.browseRegions(for: Locale.Region("GB"))
        #expect(britain.first == .ukAndIreland)
        #expect(britain[1] == .germany)

        #expect(SportsCatalog.browseRegions(for: Locale.Region("ZZ")) == base)
        #expect(SportsCatalog.browseRegions(for: nil) == base)
    }
}
