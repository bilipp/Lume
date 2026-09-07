//
//  OnboardingLocalizationTests.swift
//  LumeTests
//
//  Locks the "How Lume Works" guide's copy into all nine languages.
//  `String(localized:)` can't prove a key is in the catalog — an English key
//  resolves to itself either way — so the catalog is read directly.
//

import Foundation
@testable import Lume
import Testing

struct OnboardingLocalizationTests {
    private static let expectedLanguages: Set<String> = ["de", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"]

    /// Keys the onboarding guide added.
    private static let addedKeys = [
        "How Lume Works",
        "A quick tour of the app. It takes less than a minute.",
        "Continue",
        "Skip",
        "Lume is a player",
        "It ships with no channels, streams, or content of its own — it gives what you already pay for "
            + "a native home on every Apple device.",
        "Bring your own service",
        "Sign in with your own Xtream Codes credentials or point Lume at an M3U playlist. "
            + "The catalog is indexed on device, so browsing stays instant.",
        "Your library, organized",
        "Movies and Series arrive sorted by category and enriched with artwork, cast, trailers and ratings. "
            + "Your progress follows you across your devices.",
        "Flip through channels with a full TV Guide, see what is on now, "
            + "and jump straight back to the last thing you watched.",
        "Find any channel, movie or episode across every playlist you have added, as you type.",
        "Press Play/Pause on the Home screen to change playlist or profile without losing your place.",
        "Watch up to four live channels side by side on the big screen."
    ]

    /// Keys the guide reuses deliberately rather than adding near-duplicates.
    private static let reusedKeys = [
        "Live TV",
        "Search",
        "Quick Switch",
        "Multi-View",
        "Add Playlist",
        "Done",
        "Press Menu to close"
    ]

    private static var allKeys: [String] {
        addedKeys + reusedKeys
    }

    @Test func `literals resolve to a non empty string`() {
        for key in Self.allKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    @Test func `literals are translated in every locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
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
