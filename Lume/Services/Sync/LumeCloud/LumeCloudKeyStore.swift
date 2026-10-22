import Foundation
import Security

/// The Lume Cloud account this Apple ID belongs to. Never log it: the root key
/// decrypts every record and derives the auth token.
nonisolated struct LumeCloudIdentity: Codable, Equatable, CustomStringConvertible, CustomReflectable {
    var accountId: String
    /// The account's 32-byte root key.
    var rootKey: Data

    var description: String {
        "LumeCloudIdentity(<redacted>)"
    }

    var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// Keychain storage for the Lume Cloud identity: one synchronizable
/// data-protection generic password, so iCloud Keychain carries it to the
/// user's other Apple devices. `SyncedBackendChoice` holds a second copy and
/// wins when the two disagree.
///
/// `AfterFirstUnlock` because the transport flushes while the device is locked
/// (pre-suspension, background push). Synchronizable items cannot use a
/// `ThisDeviceOnly` class.
///
/// Every query names `kSecAttrSynchronizable` explicitly: a query without it
/// matches only non-synchronizable items.
nonisolated struct LumeCloudKeyStore {
    static let defaultService = "lume.cloud"
    private static let account = "identity"

    /// The result of a read. `unavailable` must never be treated as `notSet`:
    /// the keychain refused the read, which says nothing about whether an
    /// identity exists.
    enum Stored: Equatable {
        case identity(LumeCloudIdentity)
        case notSet
        case unavailable
    }

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func load() -> Stored {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notSet }
        guard status == errSecSuccess,
              let data = result as? Data,
              let identity = try? JSONDecoder().decode(LumeCloudIdentity.self, from: data)
        else { return .unavailable }
        return .identity(identity)
    }

    /// Stores `identity`, replacing any existing one. False when the keychain
    /// refused the write.
    @discardableResult
    func save(_ identity: LumeCloudIdentity) -> Bool {
        guard let data = try? JSONEncoder().encode(identity) else { return false }
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

    /// Removes the identity on this device and, through iCloud Keychain, on the
    /// user's other Apple devices. A missing item counts as success.
    @discardableResult
    func clear() -> Bool {
        var query = baseQuery
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
