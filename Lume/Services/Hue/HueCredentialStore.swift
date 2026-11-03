//
//  HueCredentialStore.swift
//  Lume
//
//  The one paired Hue Bridge: its id and host in UserDefaults, its application
//  key, client key and pinned certificate in the keychain. Device-local only —
//  never iCloud Keychain, never SwiftData — and one bridge per device, so
//  pairing another forgets the first.
//

import Foundation
import Security

nonisolated struct HueBridgeAddress: Hashable {
    /// The bridge id, lowercase hex as the bridge reports it; also its
    /// certificate's common name.
    var id: String
    var host: String
}

/// What the keychain holds for a bridge.
nonisolated struct HueBridgeSecrets: Codable, Hashable {
    var credentials: HueBridgeCredentials
    /// SHA-256 of the bridge's leaf certificate, pinned on first use when the
    /// chain doesn't verify against the Signify root.
    var certificatePin: Data?
}

nonisolated extension HueBridgeSecrets: HueRedacted {}

/// Prints and mirrors as `TypeName(redacted)`, so a secret or LAN address
/// never reaches a log through interpolation or `dump`.
nonisolated protocol HueRedacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}

nonisolated extension HueRedacted {
    var description: String {
        "\(Self.self)(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated struct HueCredentialStore {
    static let defaultService = "bilipp.Lume.hue"

    private typealias Keys = PlayerSettings.Hue

    var service: String
    var defaults: UserDefaults

    init(service: String = Self.defaultService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    /// The paired bridge, or nil when none is paired or its keys are gone.
    var pairedBridge: HueBridgeAddress? {
        pairedBridgeAndSecrets()?.address
    }

    /// A bridge id and host are stored; doesn't reach the keychain, so the
    /// keys may still be missing.
    var hasPairing: Bool {
        pairedID != nil && !(defaults.string(forKey: Keys.bridgeHostKey) ?? "").isEmpty
    }

    /// The paired bridge with its secrets, read from the keychain once; nil
    /// when none is paired or on any keychain or decode miss.
    func pairedBridgeAndSecrets() -> (address: HueBridgeAddress, secrets: HueBridgeSecrets)? {
        guard let id = pairedID,
              let host = defaults.string(forKey: Keys.bridgeHostKey), !host.isEmpty,
              let secrets = loadSecrets(bridgeID: id)
        else { return nil }
        return (HueBridgeAddress(id: id, host: host), secrets)
    }

    /// The paired bridge's secrets, or nil on any keychain or decode miss.
    func loadSecrets() -> HueBridgeSecrets? {
        pairedID.flatMap(loadSecrets(bridgeID:))
    }

    private var pairedID: String? {
        guard let id = defaults.string(forKey: Keys.bridgeIDKey), !id.isEmpty else { return nil }
        return id
    }

    /// Stores a newly paired bridge. A different bridge paired before is
    /// forgotten first, with its area choice and pending restore.
    @discardableResult
    func savePairing(_ secrets: HueBridgeSecrets, for bridge: HueBridgeAddress) -> Bool {
        if let previous = defaults.string(forKey: Keys.bridgeIDKey), previous != bridge.id {
            forget()
        }
        guard writeSecrets(secrets, bridgeID: bridge.id) else { return false }
        defaults.set(bridge.id, forKey: Keys.bridgeIDKey)
        defaults.set(bridge.host, forKey: Keys.bridgeHostKey)
        return true
    }

    /// Removes the paired bridge's keys, address, area choice and pending
    /// restore. Nothing paired counts as success.
    @discardableResult
    func forget() -> Bool {
        var removed = true
        if let id = defaults.string(forKey: Keys.bridgeIDKey) {
            let status = SecItemDelete(baseQuery(bridgeID: id) as CFDictionary)
            removed = status == errSecSuccess || status == errSecItemNotFound
        }
        defaults.removeObject(forKey: Keys.bridgeIDKey)
        defaults.removeObject(forKey: Keys.bridgeHostKey)
        Keys.setEntertainmentAreaID(nil, in: defaults)
        Keys.clearRestoreSnapshot(in: defaults)
        return removed
    }

    // MARK: - Keychain

    private func baseQuery(bridgeID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bridgeID,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func loadSecrets(bridgeID: String) -> HueBridgeSecrets? {
        var query = baseQuery(bridgeID: bridgeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(HueBridgeSecrets.self, from: data)
    }

    private func writeSecrets(_ secrets: HueBridgeSecrets, bridgeID: String) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        let query = baseQuery(bridgeID: bridgeID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery = query.merging(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
