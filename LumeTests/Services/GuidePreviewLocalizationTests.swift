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
    /// The Settings › Player › Live TV toggle and its footnote, plus the
    /// Lume Pro paywall entry (the toggle shares the feature title's key).
    static let newKeys = [
        "Guide Preview",
        "Plays the focused channel muted in the Guide. Uses a provider connection while you browse.",
        "Preview the focused channel, muted, right in the TV Guide."
    ]

    /// Existing keys the preview pane and the retry-less tile reuse.
    static let reusedKeys = [
        "Stream unavailable"
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
