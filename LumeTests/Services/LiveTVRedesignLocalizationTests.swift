//
//  LiveTVRedesignLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the tvOS Live TV redesign added, asserted present
//  and translated in all nine shipping locales, with the printf arguments of
//  each translation matching its key. The catalog is read directly: an English
//  key resolves to itself whether or not it is catalogued.
//

import Foundation
@testable import Lume
import Testing

@Suite("Live TV redesign localization")
struct LiveTVRedesignLocalizationTests {
    /// The now-playing hero, the guide's ruler, empty cells and hint, and the
    /// Settings › Live TV layout row with its footnote.
    static let newKeys = [
        "%lld min left",
        "Up next · %@ %@",
        "Today · %@",
        "No Programme",
        "Hold a channel to add it to Favorites or Multi-View",
        "Live TV Layout",
        "How the Live TV tab shows channels: Guide lays them out on a programme timeline, List as a plain channel list."
    ]

    /// Existing keys the hero, layout values and the guide's VoiceOver
    /// actions reuse.
    static let reusedKeys = [
        "LIVE",
        "List",
        "Guide",
        "No programme information",
        "Catch-up available",
        "Start Multi-View",
        "Add to Favorites",
        "Remove from Favorites"
    ]

    @Test func `every Live TV redesign string is translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys + Self.reusedKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `translations keep the key's format arguments`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys {
            let expected = Self.formatArguments(in: key)
            for (language, value) in catalog.localizations(for: key) ?? [:] {
                #expect(
                    Self.formatArguments(in: value) == expected,
                    "\(key) in \(language) changes its arguments: \(value)"
                )
            }
        }
    }

    /// The argument types in order of their position, so a translation may
    /// reorder with `%2$@` but never drop, add or retype one.
    private static func formatArguments(in format: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?(lld|@)/
        var sequential = 0
        return format.matches(of: pattern)
            .map { match -> (Int, String) in
                sequential += 1
                let position = match.1.flatMap { Int($0) } ?? sequential
                return (position, String(match.2))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}
