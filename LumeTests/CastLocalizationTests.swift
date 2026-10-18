//
//  CastLocalizationTests.swift
//  LumeTests
//
//  Every user-facing string the Chromecast feature added, asserted present and
//  translated in all nine shipping locales. Most of them only compile on iOS,
//  so the catalog is read directly rather than resolved.
//

import Foundation
@testable import Lume
import Testing

@Suite("Cast localization")
struct CastLocalizationTests {
    static let newKeys = [
        "cast.mini-controller.open-hint",
        "player.cast.button",
        "player.cast.casting",
        "player.cast.casting-to",
        "player.cast.device.unnamed",
        "player.cast.error.load-failed",
        "player.cast.error.playback-failed",
        "player.cast.error.title",
        "player.cast.sheet.airplay",
        "player.cast.sheet.chromecast",
        "player.cast.sheet.connecting",
        "player.cast.sheet.local-network-hint",
        "player.cast.sheet.no-devices",
        "player.cast.sheet.searching",
        "player.cast.sheet.title",
        "player.cast.stop",
        "player.cast.unavailable.format",
        "player.cast.unavailable.header-auth",
        "player.cast.unavailable.local-file",
        "player.cast.unavailable.needs-resolution",
        "player.cast.unavailable.protocol",
        "player.cast.unavailable.recording",
        "player.cast.volume",
        "premium.chromecast.subtitle",
        "premium.chromecast.title"
    ]

    /// Keys whose value takes the Chromecast's name.
    static let deviceNameKeys = [
        "player.cast.casting-to",
        "player.cast.sheet.connecting"
    ]

    @Test func `every cast string is translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test(arguments: deviceNameKeys)
    func `every translation keeps the device name placeholder`(key: String) throws {
        let catalog = try StringCatalog.localizable()
        let translations = try #require(catalog.localizations(for: key))
        for (language, value) in translations {
            #expect(value.contains("%@"), "\(key) drops the device name in \(language)")
        }
    }
}
