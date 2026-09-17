//
//  OpenSubtitlesSessionStore.swift
//  Lume
//
//  Keychain-backed persistence for the OpenSubtitles user session. The token is
//  a credential, so it lives in the keychain rather than UserDefaults —
//  encrypted at rest and excluded from plaintext backups. Mirrors
//  `TraktTokenStore`: the safe add-or-update SecItem pattern, `AfterFirstUnlock`
//  accessibility, and `kSecUseDataProtectionKeychain` so macOS behaves like
//  iOS/tvOS.
//

import Foundation
import Security

/// Reads and writes the OpenSubtitles session in the keychain. Stateless and
/// thread-safe — the keychain itself serializes access.
enum OpenSubtitlesSessionStore {
    private static let service = "bilipp.Lume.opensubtitles"
    private static let account = "user-session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// The stored session, or nil when the user has never signed in (or signed
    /// out). Any decode/keychain miss reads as "no session" rather than throwing.
    static func load() -> OpenSubtitlesSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OpenSubtitlesSession.self, from: data)
    }

    /// Saves the session, replacing any existing one. Update-then-add so item
    /// metadata survives and there's no delete/add race.
    @discardableResult
    static func save(_ session: OpenSubtitlesSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Removes the stored session. A missing item counts as success — the
    /// desired end state (no session) is already met.
    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
