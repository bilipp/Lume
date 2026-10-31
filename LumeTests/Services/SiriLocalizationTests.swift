//
//  SiriLocalizationTests.swift
//  LumeTests
//
//  Siri only matches a phrase in a language whose AppShortcuts catalog carries
//  it, and drops a phrase that loses `${applicationName}` or its parameter, so
//  the catalog is asserted directly rather than through runtime resolution.
//

import Foundation
@testable import Lume
import Testing

@Suite("Siri phrase localization")
struct SiriLocalizationTests {
    /// The phrases `LumeShortcuts` declares, one list per shortcut. The catalog
    /// keys each shortcut by its first phrase and holds every phrase of it as
    /// one string set per language.
    private static let shortcuts: [[String]] = [
        [
            "Play ${channel} in ${applicationName}",
            "Watch ${channel} in ${applicationName}",
            "Play a channel in ${applicationName}"
        ],
        [
            "Start ${movie} in ${applicationName}",
            "Play ${movie} in ${applicationName}",
            "Start a movie in ${applicationName}"
        ],
        [
            "Play ${series} in ${applicationName}",
            "Continue ${series} in ${applicationName}",
            "Play a series in ${applicationName}"
        ],
        [
            "Continue watching in ${applicationName}",
            "Resume watching in ${applicationName}"
        ]
    ]

    private static let parameters = ["${channel}", "${movie}", "${series}"]

    private static func catalog() throws -> [String: [String: Any]] {
        let url = repoRootURL().appendingPathComponent("Lume/AppShortcuts.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    /// The phrases of every locale whose string set is `translated` and non-empty.
    private static func translations(in entry: [String: Any]) -> [String: [String]] {
        var values: [String: [String]] = [:]
        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        for (language, value) in localizations {
            guard let set = (value as? [String: Any])?["stringSet"] as? [String: Any],
                  set["state"] as? String == "translated",
                  let phrases = set["values"] as? [String],
                  !phrases.isEmpty, !phrases.contains(where: \.isEmpty)
            else { continue }
            values[language] = phrases
        }
        return values
    }

    @Test func `catalog carries exactly the declared phrases`() throws {
        let catalog = try Self.catalog()
        #expect(Set(catalog.keys) == Set(Self.shortcuts.map { $0[0] }))
        for phrases in Self.shortcuts {
            let entry = try #require(catalog[phrases[0]])
            #expect(Self.translations(in: entry)["en"] == phrases)
        }
    }

    @Test func `every phrase is translated in every shipping locale`() throws {
        let catalog = try Self.catalog()
        for phrases in Self.shortcuts {
            let entry = try #require(catalog[phrases[0]])
            let translations = Self.translations(in: entry)
            let missing = shippingLocales.filter { translations[$0]?.count != phrases.count }.sorted()
            #expect(missing.isEmpty, "\(phrases[0]) is untranslated in \(missing)")
        }
    }

    @Test func `every translation keeps the app name and the phrase's parameter`() throws {
        let catalog = try Self.catalog()
        for phrases in Self.shortcuts {
            let entry = try #require(catalog[phrases[0]])
            for (language, translated) in Self.translations(in: entry) {
                for (source, value) in zip(phrases, translated) {
                    #expect(value.contains("${applicationName}"), "\(language) \(source) drops ${applicationName}")
                    for parameter in Self.parameters {
                        #expect(
                            value.contains(parameter) == source.contains(parameter),
                            "\(language) \(source) mismatches \(parameter)"
                        )
                    }
                }
            }
        }
    }
}
