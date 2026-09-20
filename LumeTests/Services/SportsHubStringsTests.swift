//
//  SportsHubStringsTests.swift
//  LumeTests
//
//  Every user-facing literal the Sports Hub added. String(localized:) can't
//  prove a key is in the catalog — an English key resolves to itself either
//  way — so the catalog is read directly and every locale is asserted.
//

import Foundation
@testable import Lume
import Testing

struct SportsHubStringsTests {
    private static let expectedLanguages: Set<String> = ["de", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"]

    /// Keys the Sports Hub feature added across its views, settings pane,
    /// premium entry, Home section and sync error states.
    private static let sportsKeys: [String] = [
        "Add leagues and teams to see fixtures, live scores and standings, with one tap to the "
            + "channel carrying the game.",
        "%@ versus %@",
        "%@, rank %lld",
        "%lld points",
        "%lld to %lld",
        "D",
        "Draws %lld",
        "GD",
        "GP",
        "Games played %lld",
        "Goal difference %lld",
        "L",
        "Losses %lld",
        "PTS",
        "Postponed",
        "RK",
        "Team",
        "W",
        "Watch on %@",
        "Wins %lld",
        "Americas",
        "Combat Sports",
        "Constructors",
        "Drag to reorder — the first few lead the Home shelf.",
        "Drivers",
        "Europe",
        "FT",
        "Final",
        "Fixtures, live scores and standings refresh automatically in the background at this interval.",
        "Follow",
        "Follow %@",
        "Follow Your Teams",
        "Follow leagues and teams below to build your Sports Hub.",
        "Follow leagues and teams to build your Sports Hub.",
        "Follow leagues and teams to build your Sports Hub. Fixtures, live scores and standings "
            + "come from ESPN, and each game links to a channel in your playlists.",
        "Follow leagues and teams to see fixtures, live scores and standings here.",
        "Follow your leagues and teams — fixtures, live scores, standings and one tap to the "
            + "channel that's carrying the game.",
        "Following",
        "France",
        "Free Practice 1",
        "Free Practice 2",
        "Free Practice 3",
        "Qualifying",
        "Race",
        "Sprint",
        "Sprint Qualifying",
        "American Football",
        "Australian Football",
        "Baseball",
        "Basketball",
        "National Teams",
        "Netherlands",
        "Portugal",
        "Rest of World",
        "Rugby",
        "Women's Football",
        "Game",
        "Germany",
        "Ice Hockey",
        "International Club Cups",
        "Italy",
        "Lacrosse",
        "Last Refreshed",
        "Last refreshed %@",
        "Leagues",
        "Lineup",
        "Loading teams…",
        "Manage Teams",
        "Motorsport",
        "My Teams",
        "Never",
        "No Teams",
        "No Teams Followed",
        "No games",
        "Not in your channels",
        "On Your Channels",
        "Open Detail",
        "PP",
        "Pick Channel…",
        "Range",
        "Refresh Now",
        "Refreshing…",
        "Scope",
        "Scores and schedules provided by ESPN",
        "Scores unavailable — showing your saved data.",
        "Search every league",
        "See All",
        "Select a row to lift it, then move up or down and select again to place — the first few "
            + "lead the Home shelf.",
        "Show Sports Tab",
        "Show the Sports tab. The fixtures rail on Home follows your Home layout settings.",
        "Spain",
        "Sports",
        "Sports Data",
        "Sports Hub",
        "Sports haven't refreshed yet.",
        "Standings",
        "Stats",
        "Table",
        "Teams",
        "This league's teams aren't available right now.",
        "Timeline",
        "Today",
        "Tomorrow",
        "UK & Ireland",
        "Unfollow",
        "Unfollow %@",
        "Unlock Sports Hub",
        "Updating guide…",
        "Yesterday",
        "★ My Teams"
    ]

    @Test func `sports literals resolve to A non empty string`() {
        for key in Self.sportsKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    @Test func `sports literals are translated in every locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.sportsKeys {
            let localizations = try #require(catalog.localizations(for: key), "\(key) is not in the catalog")
            #expect(
                Self.expectedLanguages.isSubset(of: Set(localizations.keys)),
                "\(key) is missing locales: \(Self.expectedLanguages.subtracting(localizations.keys).sorted())"
            )
            for (language, value) in localizations {
                #expect(!value.isEmpty, "\(key) is untranslated in \(language)")
            }
        }
    }
}
