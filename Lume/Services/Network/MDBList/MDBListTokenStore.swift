//
//  MDBListTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the MDBList OAuth token set. Tokens are
//  secrets, so they live in the keychain rather than UserDefaults — encrypted
//  at rest and excluded from plaintext backups.
//
//  Mirrors `SimklTokenStore`: SecItem directly with the safe update-then-add
//  pattern, `AfterFirstUnlock` accessibility so a refresh can succeed while the
//  device is locked, and `kSecUseDataProtectionKeychain` to keep macOS aligned
//  with iOS/tvOS behaviour.
//

import Foundation
import Security

/// The OAuth token set returned by MDBList's `/oauth/token/`, plus the metadata
/// needed to know when the access token needs refreshing.
struct MDBListTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix timestamp (seconds) when the access token was issued — captured
    /// client-side, as the token response carries no `created_at`.
    var issuedAt: TimeInterval
    /// Lifetime of the access token in seconds — 30 days.
    var expiresIn: TimeInterval
    var scope: String?

    var expiryDate: Date {
        Date(timeIntervalSince1970: issuedAt + expiresIn)
    }

    /// Whether the token has expired or is within a day of doing so.
    var needsRefresh: Bool {
        expiryDate.timeIntervalSinceNow < 60 * 60 * 24
    }
}

/// Reads and writes the MDBList token set in the keychain. Stateless and
/// thread-safe — the keychain itself serializes access.
enum MDBListTokenStore {
    private static let service = "bilipp.Lume.mdblist"
    private static let account = "oauth-tokens"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// The stored token set, or nil if the user has never connected (or
    /// disconnected). Any decode/keychain miss reads as "no usable token".
    static func load() -> MDBListTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(MDBListTokens.self, from: data)
    }

    @discardableResult
    static func save(_ tokens: MDBListTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }

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

    /// A missing item counts as success — the desired end state is met.
    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
