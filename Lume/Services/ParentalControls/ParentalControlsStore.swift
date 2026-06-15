//
//  ParentalControlsStore.swift
//  Lume
//
//  Keychain-backed storage for the parental-control PIN. The PIN gates leaving a
//  child profile and editing Content Management; it isn't a high-value secret,
//  but it lives in the keychain (encrypted at rest, excluded from plaintext
//  backups) rather than UserDefaults — and only a salted SHA-256 hash is stored,
//  never the PIN itself, so a keychain dump can't reveal a PIN the user might
//  reuse elsewhere.
//
//  Mirrors `TraktTokenStore`: SecItem directly with the safe update-then-add
//  pattern, `kSecUseDataProtectionKeychain` for macOS parity. `WhenUnlocked`
//  accessibility fits a PIN that's only ever read while the app is foregrounded.
//

import CryptoKit
import Foundation
import Security

enum ParentalControlsStore {
    private static let service = "bilipp.Lume.parental"
    private static let account = "pin-hash"
    /// Mixed into the hash. Not a secret (it ships in the binary); it only stops
    /// the stored value from being a bare SHA-256 of a four-digit PIN.
    private static let salt = "lume.parental.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Whether a PIN has been set. A presence check — never returns the hash.
    static var isSet: Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores the salted hash of `pin`, replacing any existing one.
    static func save(pin: String) {
        let data = Data(hash(pin).utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Whether `pin` matches the stored PIN. False when no PIN is set.
    static func verify(pin: String) -> Bool {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = String(data: data, encoding: .utf8)
        else { return false }
        return stored == hash(pin)
    }

    /// Removes the stored PIN. A missing item is treated as success.
    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
