import Foundation
import Security

/// Only an opaque reference and a "required" marker enter SwiftData. Neither the
/// identity nor its Keychain reference is mirrored to either sync backend.
nonisolated struct StalkerIdentityStore {
    var service = (Bundle.main.bundleIdentifier ?? "Lume") + ".stalker-identity"

    private struct Record: Codable {
        let account: [String]
        let identity: StalkerIdentity
    }

    private func account(_ playlist: Playlist) -> [String] {
        [playlist.serverURL, playlist.macAddress ?? "", playlist.username, playlist.password]
    }

    private func query(_ reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func load(for playlist: Playlist) throws -> StalkerIdentity {
        guard playlist.stalkerIdentityRequired || playlist.stalkerIdentityReference != nil else { return StalkerIdentity() }
        guard let reference = playlist.stalkerIdentityReference else { throw StalkerIdentityError.localIdentityRequired }
        var lookup = query(reference)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? StalkerIdentityError.localIdentityRequired : StalkerIdentityError.storageUnavailable
        }
        guard let data = result as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.account == account(playlist)
        else { throw StalkerIdentityError.localIdentityRequired }
        return record.identity
    }

    /// Write a new immutable item before changing the reference. A failed write
    /// leaves the previous identity intact.
    func save(_ identity: StalkerIdentity, for playlist: Playlist) throws {
        try identity.validate()
        let oldReference = playlist.stalkerIdentityReference
        if identity.isConfigured {
            let reference = UUID().uuidString
            var item = query(reference)
            item[kSecValueData as String] = try JSONEncoder().encode(Record(account: account(playlist), identity: identity))
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StalkerIdentityError.storageUnavailable }
            playlist.stalkerIdentityReference = reference
        } else {
            playlist.stalkerIdentityReference = nil
        }
        playlist.stalkerIdentityRequired = identity.isConfigured
        if let oldReference { remove(reference: oldReference) }
    }

    func remove(reference: String) {
        SecItemDelete(query(reference) as CFDictionary)
    }
}
