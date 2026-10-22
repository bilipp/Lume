import Foundation
@testable import Lume
import Testing

/// Serialized because every test touches the same keychain item. Uses its own
/// service so a run never clobbers a real identity on the simulator.
@Suite(.serialized)
struct LumeCloudKeyStoreTests {
    private let store = LumeCloudKeyStore(service: "lume.cloud.tests")

    private func identity(accountId: String = "acct-test-1", byte: UInt8 = 0xAB) -> LumeCloudIdentity {
        LumeCloudIdentity(accountId: accountId, rootKey: Data(repeating: byte, count: 32))
    }

    init() {
        store.clear()
    }

    @Test func `default service is lume.cloud`() {
        #expect(LumeCloudKeyStore().service == "lume.cloud")
    }

    @Test func `load reports not set when empty`() {
        #expect(store.load() == .notSet)
    }

    @Test func `save then load round trips`() {
        defer { store.clear() }
        #expect(store.save(identity()))
        #expect(store.load() == .identity(identity()))
    }

    @Test func `save replaces the existing identity`() {
        defer { store.clear() }
        #expect(store.save(identity()))
        #expect(store.save(identity(accountId: "acct-test-2", byte: 0x01)))
        #expect(store.load() == .identity(identity(accountId: "acct-test-2", byte: 0x01)))
    }

    @Test func `clear removes the identity`() {
        #expect(store.save(identity()))
        #expect(store.clear())
        #expect(store.load() == .notSet)
    }

    @Test func `clear on a missing item succeeds`() {
        #expect(store.clear())
    }

    @Test func `item is synchronizable and after first unlock`() throws {
        defer { store.clear() }
        #expect(store.save(identity()))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == true)
    }

    @Test func `identity description hides secrets`() {
        let value = identity()
        #expect(!String(describing: value).contains(value.accountId))
        #expect(!String(reflecting: value).contains(value.accountId))
        #expect(Mirror(reflecting: value).children.isEmpty)
    }
}

struct LumeCloudSettingsTests {
    private let suiteName: String
    private let defaults: UserDefaults
    private let settings: LumeCloudSettings

    init() throws {
        suiteName = "LumeCloudSettingsTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = LumeCloudSettings(defaults: defaults)
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func `backend defaults to icloud`() {
        defer { cleanUp() }
        #expect(LumeCloudSettings.defaultBackend == .icloud)
        #expect(settings.backend == .icloud)
    }

    @Test func `backend persists under sync.backend`() {
        defer { cleanUp() }
        settings.backend = .lumecloud
        #expect(defaults.string(forKey: "sync.backend") == "lumecloud")
        #expect(LumeCloudSettings(defaults: defaults).backend == .lumecloud)
        settings.backend = .off
        #expect(settings.backend == .off)
    }

    @Test func `unknown backend reads as the default`() {
        defer { cleanUp() }
        defaults.set("somethingNew", forKey: "sync.backend")
        #expect(settings.backend == LumeCloudSettings.defaultBackend)
    }

    @Test func `device id is generated once and stable`() {
        defer { cleanUp() }
        #expect(defaults.string(forKey: "lumecloud.deviceID") == nil)
        let first = settings.deviceID
        #expect(defaults.string(forKey: "lumecloud.deviceID") == first.uuidString)
        #expect(settings.deviceID == first)
    }

    @Test func `rotating the device id replaces it`() {
        defer { cleanUp() }
        let first = settings.deviceID
        let rotated = settings.rotateDeviceID()
        #expect(rotated != first)
        #expect(settings.deviceID == rotated)
    }

    @Test func `device name defaults to the generic model name`() {
        defer { cleanUp() }
        #expect(settings.deviceName == LumeCloudSettings.genericModelName)
        #expect(["iPhone", "iPad", "Mac", "Apple TV", "Apple Vision Pro"].contains(LumeCloudSettings.genericModelName))
    }

    @Test func `device name is trimmed and blank restores the default`() {
        defer { cleanUp() }
        settings.deviceName = "  Living Room Tablet  "
        #expect(settings.deviceName == "Living Room Tablet")
        settings.deviceName = "   "
        #expect(defaults.object(forKey: "lumecloud.deviceName") == nil)
        #expect(settings.deviceName == LumeCloudSettings.genericModelName)
    }

    @Test func `recovery key viewed defaults to false and persists`() {
        defer { cleanUp() }
        #expect(settings.recoveryKeyViewed == false)
        settings.recoveryKeyViewed = true
        #expect(LumeCloudSettings(defaults: defaults).recoveryKeyViewed)
    }
}
