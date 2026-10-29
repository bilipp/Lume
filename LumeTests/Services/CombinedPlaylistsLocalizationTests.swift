//
//  CombinedPlaylistsLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal Combined playlists (#204) added, asserted present
//  and translated in every shipping locale with the English printf
//  specifiers intact.
//

import Foundation
@testable import Lume
import Testing

@Suite("Combined playlists localization")
struct CombinedPlaylistsLocalizationTests {
    /// The selection's name in the switcher, quick switch and Multi-View, and
    /// the tvOS quick-switch subtitle while fewer than two playlists are combined.
    static let selectionKeys = [
        "Combined",
        "Choose playlists to combine in Settings"
    ]

    /// Settings › Combined View on every platform, including the VoiceOver
    /// labels of the per-playlist toggles and the tvOS reorder action.
    static let settingsKeys = [
        "Combined View",
        "Browse Live TV, Movies and Series from several playlists together.",
        "Combined View is part of Lume Pro. Your choices here are kept.",
        "Combined View merges the content types you choose from each playlist into one library, grouped by playlist. "
            + "Include at least two playlists, then choose Combined in the playlist switcher.",
        "Combined View merges the content types you choose from each playlist into one library, grouped by playlist. "
            + "Include at least two playlists, then choose Combined in Quick Switch (Play/Pause).",
        "Each playlist's categories appear in this order. Drag to reorder.",
        "Select a playlist to move it. Select its pencil to choose its content types.",
        "Include in Combined View",
        "Include %@ in Combined View",
        "Include %@ from %@",
        "Not Included"
    ]

    /// The footers that explain per-playlist settings while Combined is selected.
    static let footerKeys = [
        "In Combined View, Movies, Series and Live TV follow each playlist's content types. Sports applies to every playlist.",
        "In Combined View, hidden and reordered categories still belong to each playlist. Pick the playlist to manage.",
        "Combined orders your favorites across every playlist. Pick a playlist to arrange only its favorites."
    ]

    /// The provenance badge's VoiceOver label and the error shown when an
    /// item's owning playlist no longer exists.
    static let browseKeys = [
        "from %@",
        "Playlist Not Found",
        "This item's playlist could not be found."
    ]

    static var allKeys: [String] {
        selectionKeys + settingsKeys + footerKeys + browseKeys
    }

    @Test func `every Combined playlists string is translated in every shipping locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `every translation keeps the English format specifiers`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
            let expected = Self.specifiers(in: key)
            let translations = try #require(catalog.localizations(for: key), "\(key) is not in the string catalog")
            for (locale, value) in translations {
                #expect(Self.specifiers(in: value) == expected, "\(locale) changes the specifiers of \(key)")
            }
        }
    }

    @Test func `every Combined playlists string resolves to a non empty value`() {
        for key in Self.allKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    /// The conversion of every printf specifier, positional or not, sorted so a
    /// translation may reorder its arguments.
    private static func specifiers(in text: String) -> [String] {
        let pattern = #/%(?:\d+\$)?(@|lld|ld|d|f)/#
        return text.matches(of: pattern).map { String($0.output.1) }.sorted()
    }
}
