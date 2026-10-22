//
//  QualitySwitchLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the live quality switch added, asserted present
//  and translated in every shipping locale. The tvOS button and settings row
//  only compile on tvOS, so the catalog is read directly rather than resolved.
//

import Foundation
@testable import Lume
import Testing

@Suite("Quality switch localization")
struct QualitySwitchLocalizationTests {
    /// The player menu's label, the untagged variant's title, and the settings
    /// toggle with its footer.
    static let newKeys = [
        "Quality",
        "Standard",
        "Show Quality Switch",
        "While watching a live channel, switch to the same channel in another quality, such as HD, FHD or 4K, when your playlist lists it more than once."
    ]

    @Test func `every quality switch string is translated in every shipping locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `translations keep the quality tags untranslated`() throws {
        let catalog = try StringCatalog.localizable()
        let footer = Self.newKeys[3]
        let translations = try #require(catalog.localizations(for: footer))
        for (language, value) in translations {
            for tag in ["HD", "FHD", "4K"] {
                #expect(value.contains(tag), "\(language) footer drops \(tag)")
            }
        }
    }
}
