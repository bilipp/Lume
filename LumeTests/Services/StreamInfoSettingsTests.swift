import Foundation
@testable import Lume
import Testing

struct StreamInfoDetailLevelTests {
    @Test func `raw values are stable`() {
        #expect(StreamInfoDetailLevel.simple.rawValue == "simple")
        #expect(StreamInfoDetailLevel.advanced.rawValue == "advanced")
        #expect(StreamInfoDetailLevel.allCases == [.simple, .advanced])
    }

    @Test func `identifiable id is the raw value`() {
        for level in StreamInfoDetailLevel.allCases {
            #expect(level.id == level.rawValue)
        }
    }

    @Test func `titles and footers are non empty`() {
        for level in StreamInfoDetailLevel.allCases {
            #expect(!String(localized: level.title).isEmpty)
            #expect(!String(localized: level.footer).isEmpty)
        }
    }

    @Test func `unknown raw value does not decode`() {
        #expect(StreamInfoDetailLevel(rawValue: "verbose") == nil)
    }
}

struct StreamInfoSettingsDefaultsTests {
    @Test func `storage keys are stable`() {
        #expect(PlayerSettings.StreamInfo.enabledKey == "player.streamInfo.enabled")
        #expect(PlayerSettings.StreamInfo.detailLevelKey == "player.streamInfo.detailLevel")
    }

    /// Opt-in everywhere off tvOS; tvOS never consults this key at all, because
    /// its caption is always-on chrome.
    @Test func `caption is off by default`() {
        #expect(PlayerSettings.StreamInfo.enabledDefault == false)
    }

    @Test func `detail level default matches the platform`() {
        #if os(tvOS)
            // Advanced keeps today's technical caption (`4K · H264 · 24 fps`)
            // rendering byte-identically.
            #expect(PlayerSettings.StreamInfo.detailLevelDefault == .advanced)
        #else
            #expect(PlayerSettings.StreamInfo.detailLevelDefault == .simple)
        #endif
    }

    /// The accessors read `UserDefaults.standard` directly (deliberately — an
    /// `@AppStorage` in the player host would re-render the whole player tree),
    /// so the decoding semantics are exercised against an isolated suite.
    @Test func `enabled decoding falls back to the default`() throws {
        let suiteName = "StreamInfoSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = PlayerSettings.StreamInfo.enabledKey
        #expect(defaults.bool(key, default: PlayerSettings.StreamInfo.enabledDefault) == false)

        defaults.set(true, forKey: key)
        #expect(defaults.bool(key, default: PlayerSettings.StreamInfo.enabledDefault))
    }

    @Test func `detail level decoding falls back to the default`() throws {
        let suiteName = "StreamInfoSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = PlayerSettings.StreamInfo.detailLevelKey
        func stored() -> StreamInfoDetailLevel {
            guard let raw = defaults.string(forKey: key) else {
                return PlayerSettings.StreamInfo.detailLevelDefault
            }
            return StreamInfoDetailLevel(rawValue: raw) ?? PlayerSettings.StreamInfo.detailLevelDefault
        }

        #expect(stored() == PlayerSettings.StreamInfo.detailLevelDefault)

        defaults.set(StreamInfoDetailLevel.advanced.rawValue, forKey: key)
        #expect(stored() == .advanced)

        defaults.set("verbose", forKey: key)
        #expect(stored() == PlayerSettings.StreamInfo.detailLevelDefault)
    }
}
