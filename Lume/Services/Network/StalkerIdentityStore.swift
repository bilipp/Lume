import Foundation
import Security

/// Only an opaque reference and a "required" marker enter SwiftData. Neither the
/// identity nor its Keychain reference is mirrored to either sync backend.
nonisolated struct StalkerIdentityStore {
    var service = (Bundle.main.bundleIdentifier ?? "Lume") + ".stalker-identity"

    private struct Record: Codable {
        let playlistID: UUID
        let identity: StalkerIdentity
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
              record.playlistID == playlist.id
        else { throw StalkerIdentityError.localIdentityRequired }
        return record.identity
    }

    /// Validates and writes a new immutable Keychain item for `playlistID`
    /// without mutating SwiftData, returning its reference (or `nil` when
    /// `identity` is unconfigured).
    func write(_ identity: StalkerIdentity, for playlistID: UUID) throws -> String? {
        try identity.validate()
        guard identity.isConfigured else { return nil }
        let reference = UUID().uuidString
        var item = query(reference)
        item[kSecValueData as String] = try JSONEncoder().encode(Record(playlistID: playlistID, identity: identity))
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StalkerIdentityError.storageUnavailable }
        return reference
    }

    /// Write a new immutable item before changing the reference. A failed write
    /// leaves the previous identity intact.
    func save(_ identity: StalkerIdentity, for playlist: Playlist) throws {
        let oldReference = playlist.stalkerIdentityReference
        let reference = try write(identity, for: playlist.id)
        playlist.stalkerIdentityReference = reference
        playlist.stalkerIdentityRequired = identity.isConfigured
        if let oldReference { remove(reference: oldReference) }
    }

    func remove(reference: String) {
        SecItemDelete(query(reference) as CFDictionary)
    }
}
