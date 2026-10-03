//
//  GuidePreviewLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the tvOS Guide preview added, asserted present and
//  translated in all nine shipping locales. String(localized:) can't prove a
//  key is in the catalog — an English key resolves to itself either way — so
//  the catalog is read directly.
//

import Foundation
@testable import Lume
import Testing

@Suite("Guide preview localization")
struct GuidePreviewLocalizationTests {
    /// The Settings › Player › Live TV row, its choices and footnote, plus
    /// the Lume Pro paywall entry (the row shares the feature title's key).
    static let newKeys = [
        "Guide Preview",
        "Large",
        "Small",
        "Info Only",
        "Small and Large play the focused channel muted and use a provider connection while you browse. Info Only shows it without video; Off gives the Guide the full height.",
        "Preview the focused channel, muted, right in the TV Guide."
    ]

    /// Existing keys the preview pane, the retry-less tile and the row reuse.
    static let reusedKeys = [
        "Stream unavailable",
        "Off"
    ]

    @Test func `every Guide preview string is translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys + Self.reusedKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `the premium entry uses the catalogued keys`() {
        #expect(PremiumFeature.guidePreview.title.key == "Guide Preview")
        #expect(PremiumFeature.guidePreview.subtitle.key == "Preview the focused channel, muted, right in the TV Guide.")
    }

    @Test func `paywalls outside tvOS never advertise the Guide preview`() {
        #expect(!PremiumFeature.available.contains(.guidePreview))
        #expect(PremiumFeature.available.count == PremiumFeature.allCases.count - 1)
    }
}
