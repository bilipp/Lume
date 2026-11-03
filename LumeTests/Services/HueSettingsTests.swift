import Foundation
@testable import Lume
import Testing

struct HueSettingsTests {
    private typealias Keys = PlayerSettings.Hue

    private static let snapshot = HueLightSnapshot(lights: [
        .init(lightID: "light-a", isOn: true, brightness: 62.5, color: .chromaticity(HueXY(x: 0.4573, y: 0.41))),
        .init(lightID: "light-b", isOn: false, brightness: nil, color: .mirek(366))
    ])

    @Test func `keys match the documented storage layout`() {
        #expect(Keys.enabledKey == "player.hue.enabled")
        #expect(Keys.intensityKey == "player.hue.intensity")
        #expect(Keys.entertainmentAreaKey == "hue.entertainmentArea")
        #expect(Keys.bridgeHostKey == "hue.bridge.host")
        #expect(Keys.bridgeIDKey == "hue.bridge.id")
        #expect(!Keys.restoreSnapshotKey.hasPrefix("player."))
    }

    @Test func `untouched defaults are off at moderate`() {
        withIsolatedDefaults { defaults in
            #expect(!Keys.isEnabled(in: defaults))
            #expect(Keys.intensity(in: defaults) == .moderate)
            #expect(Keys.selection(in: defaults) == .off)
            #expect(Keys.entertainmentAreaID(in: defaults) == nil)
            #expect(!Keys.lightSensitivityNoticeShown(in: defaults))
            #expect(Keys.restoreSnapshot(in: defaults) == nil)
        }
    }

    @Test func `a menu choice is the saved default and off keeps the level`() {
        withIsolatedDefaults { defaults in
            Keys.setSelection(.intense, in: defaults)
            #expect(Keys.isEnabled(in: defaults))
            #expect(Keys.selection(in: defaults) == .intense)

            Keys.setSelection(.off, in: defaults)
            #expect(!Keys.isEnabled(in: defaults))
            #expect(Keys.selection(in: defaults) == .off)
            #expect(Keys.intensity(in: defaults) == .intense)
        }
    }

    @Test func `unknown or off stored intensities fall back to the default`() {
        withIsolatedDefaults { defaults in
            defaults.set(true, forKey: Keys.enabledKey)
            defaults.set("blinding", forKey: Keys.intensityKey)
            #expect(Keys.selection(in: defaults) == .moderate)
            defaults.set("off", forKey: Keys.intensityKey)
            #expect(Keys.selection(in: defaults) == .moderate)
        }
    }

    @Test func `entertainment area round trips and clears`() {
        withIsolatedDefaults { defaults in
            Keys.setEntertainmentAreaID("8d199a37-5ce4-4aae-a60e-db5d0aa27df3", in: defaults)
            #expect(Keys.entertainmentAreaID(in: defaults) == "8d199a37-5ce4-4aae-a60e-db5d0aa27df3")
            Keys.setEntertainmentAreaID(nil, in: defaults)
            #expect(Keys.entertainmentAreaID(in: defaults) == nil)
            defaults.set("", forKey: Keys.entertainmentAreaKey)
            #expect(Keys.entertainmentAreaID(in: defaults) == nil)
        }
    }

    @Test func `light sensitivity notice is shown once`() {
        withIsolatedDefaults { defaults in
            Keys.markLightSensitivityNoticeShown(in: defaults)
            #expect(Keys.lightSensitivityNoticeShown(in: defaults))
        }
    }

    @Test func `restore snapshot persists until cleared`() {
        withIsolatedDefaults { defaults in
            Keys.saveRestoreSnapshot(Self.snapshot, in: defaults)
            #expect(Keys.restoreSnapshot(in: defaults) == Self.snapshot)
            Keys.clearRestoreSnapshot(in: defaults)
            #expect(Keys.restoreSnapshot(in: defaults) == nil)
        }
    }

    @Test func `an undecodable restore snapshot reads as none`() {
        withIsolatedDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: Keys.restoreSnapshotKey)
            #expect(Keys.restoreSnapshot(in: defaults) == nil)
        }
    }

    @Test func `diagnostic settings never list the bridge or area`() {
        withIsolatedDefaults { defaults in
            Keys.setSelection(.high, in: defaults)
            Keys.setEntertainmentAreaID("8d199a37-5ce4-4aae-a60e-db5d0aa27df3", in: defaults)
            defaults.set("192.168.178.24", forKey: Keys.bridgeHostKey)
            defaults.set("ecb5fafffe000000", forKey: Keys.bridgeIDKey)
            Keys.saveRestoreSnapshot(Self.snapshot, in: defaults)

            let lines = DebugLogExporter.settingsLines(defaults).joined(separator: "\n")
            #expect(lines.contains("player.hue.intensity = high"))
            #expect(lines.contains("player.hue.enabled = on"))
            #expect(!lines.contains("8d199a37"))
            #expect(!lines.contains("192.168.178.24"))
            #expect(!lines.contains("ecb5fafffe000000"))
            #expect(!lines.contains("light-a"))
        }
    }
}

// MARK: - HueCredentialStore (keychain)

/// Serialized: every test shares the test service's keychain items.
@Suite(.serialized)
struct HueCredentialStoreTests {
    private static let service = "bilipp.Lume.hue.tests"
    private static let bridge = HueBridgeAddress(id: "ecb5fafffe000001", host: "192.0.2.10")

    private static func secrets(key: String = "app-key", pin: Data? = nil) -> HueBridgeSecrets {
        HueBridgeSecrets(
            credentials: HueBridgeCredentials(applicationKey: key, clientKey: "00112233445566778899AABBCCDDEEFF"),
            certificatePin: pin
        )
    }

    private func withStore(_ body: (HueCredentialStore, UserDefaults) throws -> Void) rethrows {
        try withIsolatedDefaults { defaults in
            let store = HueCredentialStore(service: Self.service, defaults: defaults)
            defer { store.forget() }
            try body(store, defaults)
        }
    }

    @Test func `nothing is paired on a fresh store`() {
        withStore { store, _ in
            #expect(store.pairedBridge == nil)
            #expect(store.loadSecrets() == nil)
        }
    }

    @Test func `saving a pairing stores keys in the keychain and the address in defaults`() {
        withStore { store, defaults in
            #expect(store.savePairing(Self.secrets(), for: Self.bridge))
            #expect(store.pairedBridge == Self.bridge)
            #expect(store.loadSecrets() == Self.secrets())
            #expect(defaults.string(forKey: PlayerSettings.Hue.bridgeIDKey) == Self.bridge.id)
            #expect(defaults.string(forKey: PlayerSettings.Hue.bridgeHostKey) == Self.bridge.host)
            let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
            #expect(!stored.contains("app-key"))
        }
    }

    @Test func `pairing another bridge forgets the first with its area and restore`() {
        withStore { store, defaults in
            store.savePairing(Self.secrets(key: "first"), for: Self.bridge)
            PlayerSettings.Hue.setEntertainmentAreaID("area", in: defaults)
            PlayerSettings.Hue.saveRestoreSnapshot(HueLightSnapshot(lights: []), in: defaults)

            let other = HueBridgeAddress(id: "ecb5fafffe000002", host: "192.0.2.30")
            #expect(store.savePairing(Self.secrets(key: "second"), for: other))
            #expect(store.pairedBridge == other)
            #expect(store.loadSecrets()?.credentials.applicationKey == "second")
            #expect(PlayerSettings.Hue.entertainmentAreaID(in: defaults) == nil)
            #expect(PlayerSettings.Hue.restoreSnapshot(in: defaults) == nil)

            let firstStore = HueCredentialStore(service: Self.service, defaults: defaults)
            defaults.set(Self.bridge.id, forKey: PlayerSettings.Hue.bridgeIDKey)
            #expect(firstStore.loadSecrets() == nil)
            defaults.set(other.id, forKey: PlayerSettings.Hue.bridgeIDKey)
        }
    }

    @Test func `forget removes everything and succeeds when nothing is paired`() {
        withStore { store, defaults in
            store.savePairing(Self.secrets(), for: Self.bridge)
            #expect(store.forget())
            #expect(store.pairedBridge == nil)
            #expect(store.loadSecrets() == nil)
            #expect(defaults.string(forKey: PlayerSettings.Hue.bridgeHostKey) == nil)
            #expect(store.forget())
        }
    }

    @Test func `secrets never print their keys`() {
        let secrets = Self.secrets(key: "super-secret-key")
        #expect(!String(describing: secrets).contains("super-secret-key"))
        #expect(!String(reflecting: secrets).contains("super-secret-key"))
        #expect(!String(describing: secrets).contains("00112233"))
    }
}
