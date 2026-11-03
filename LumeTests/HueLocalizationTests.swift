//
//  HueLocalizationTests.swift
//  LumeTests
//
//  Every user-facing string the Philips Hue feature added, asserted present and
//  translated in all shipping locales. They only compile on tvOS, so the
//  catalog is read directly rather than resolved.
//

import Foundation
@testable import Lume
import Testing

@Suite("Hue localization")
struct HueLocalizationTests {
    static let newKeys = [
        "player.hue.areaInUse",
        "player.hue.title",
        "player.hue.unavailable.content",
        "player.hue.unavailable.engine",
        "premium.hueSync.subtitle",
        "premium.hueSync.title",
        "settings.hue.address.connect",
        "settings.hue.address.enter",
        "settings.hue.address.footer",
        "settings.hue.address.placeholder",
        "settings.hue.address.title",
        "settings.hue.area.channels",
        "settings.hue.area.empty",
        "settings.hue.area.loading",
        "settings.hue.area.reload",
        "settings.hue.bridge",
        "settings.hue.discovery.localNetwork",
        "settings.hue.discovery.searching",
        "settings.hue.discovery.unavailable",
        "settings.hue.error.generic",
        "settings.hue.error.invalidAddress",
        "settings.hue.error.linkButton",
        "settings.hue.error.rateLimited",
        "settings.hue.error.saveFailed",
        "settings.hue.error.unauthorized",
        "settings.hue.error.unreachable",
        "settings.hue.error.untrusted",
        "settings.hue.forget",
        "settings.hue.forget.confirm",
        "settings.hue.forget.confirmMessage",
        "settings.hue.forget.confirmTitle",
        "settings.hue.intensity",
        "settings.hue.intensity.high",
        "settings.hue.intensity.intense",
        "settings.hue.intensity.moderate",
        "settings.hue.intensity.off",
        "settings.hue.intensity.subtle",
        "settings.hue.notice.cancel",
        "settings.hue.notice.confirm",
        "settings.hue.notice.message",
        "settings.hue.notice.title",
        "settings.hue.pairing.cancel",
        "settings.hue.pairing.connecting",
        "settings.hue.pairing.instructions",
        "settings.hue.pairing.pair",
        "settings.hue.pairing.retry",
        "settings.hue.pairing.title",
        "settings.hue.pairing.waiting",
        "settings.hue.section.area",
        "settings.hue.section.bridge",
        "settings.hue.section.lights",
        "settings.hue.section.sync",
        "settings.hue.sync",
        "settings.hue.sync.footer",
        "settings.hue.test",
        "settings.hue.test.areaInUse",
        "settings.hue.test.footer",
        "settings.hue.test.streamFailed",
        "settings.hue.test.unsupportedArea"
    ]

    /// Keys whose English names the brand, which stays untranslated.
    static let brandKeys = [
        "player.hue.title",
        "premium.hueSync.subtitle",
        "premium.hueSync.title"
    ]

    /// Keys whose value carries the example bridge address verbatim.
    static let exampleAddressKeys = [
        "settings.hue.address.placeholder",
        "settings.hue.error.invalidAddress"
    ]

    @Test func `every Hue string is translated in all shipping locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `the catalog has no Hue key the suite doesn't cover`() throws {
        let catalog = try StringCatalog.localizable()
        let prefixes = ["settings.hue.", "player.hue.", "premium.hueSync."]
        let catalogKeys = catalog.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        #expect(Set(catalogKeys) == Set(Self.newKeys))
    }

    @Test(arguments: brandKeys)
    func `every translation keeps the Philips Hue brand`(key: String) throws {
        let catalog = try StringCatalog.localizable()
        let translations = try #require(catalog.localizations(for: key))
        for (language, value) in translations {
            #expect(value.contains("Philips Hue"), "\(key) translates the brand in \(language)")
        }
    }

    @Test(arguments: exampleAddressKeys)
    func `every translation keeps the example address`(key: String) throws {
        let catalog = try StringCatalog.localizable()
        let translations = try #require(catalog.localizations(for: key))
        for (language, value) in translations {
            #expect(value.contains("192.168.1.20"), "\(key) drops the example address in \(language)")
        }
    }

    @Test func `every channel count translation keeps its number`() throws {
        let catalog = try StringCatalog.localizable()
        let translations = try #require(catalog.localizations(for: "settings.hue.area.channels"))
        for (language, value) in translations {
            #expect(value.components(separatedBy: "%lld").count == 2, "channel count is not one %lld in \(language)")
        }
    }
}
