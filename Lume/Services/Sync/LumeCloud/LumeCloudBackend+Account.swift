import Foundation
import LumeCloudKit
import OSLog
import SwiftData

/// Account flows: create, join with a known identity, restore from a recovery
/// key, leave, delete. Each join starts the Lume Cloud store empty
/// (`activate(_:wipingStore:)`); switching the device's backend is the caller's.
extension LumeCloudBackend {
    // MARK: Create

    /// Creates an account, joins it and returns its recovery key. The key stays
    /// "not viewed" until `markRecoveryKeyViewed()`, which keeps the Settings badge.
    func createAccount() async throws -> String {
        try ensureCanJoin()
        let keys = LumeCloudKeys.generate()
        _ = try await makeClient(nil).createAccount(keys: keys)
        try await join(LumeCloudIdentity(accountId: keys.accountId, rootKey: keys.rootKey))
        settings.recoveryKeyViewed = false
        return LumeCloudRecoveryKey.encode(keys)
    }

    // MARK: Join

    /// Joins the account `identity` names: stores it in the keychain first (so
    /// the key is never lost after the server knows the account), registers this
    /// device, then activates with an empty store. Also the entry point for a
    /// device that already holds the identity (iCloud Keychain, `SyncedBackendChoice`).
    /// Only the device that created the account owes the user a look at the
    /// recovery key, so a join leaves no Settings badge.
    func join(_ identity: LumeCloudIdentity) async throws {
        try ensureCanJoin()
        let keys = try LumeCloudKeys(rootKey: identity.rootKey)
        try await join(identity) {
            try await retryingRevokedDevice { deviceID in
                try await registerDevice(keys: keys, deviceID: deviceID)
            }
        }
    }

    // MARK: Restore

    /// Joins the account a recovery key belongs to; the account id is derived
    /// from its root key. Registering a fresh device id is the whole sign-in
    /// (PROTOCOL.md §4.8). Any failure to register (a key no account accepts, or
    /// just a dropped connection) puts back whatever identity the synchronizable
    /// keychain held before, so other Apple devices never inherit a half-done
    /// restore.
    func restore(recoveryKey: String) async throws {
        try ensureCanJoin()
        let keys: LumeCloudKeys
        do {
            keys = try LumeCloudRecoveryKey.keys(from: recoveryKey)
        } catch LumeCloudCryptoError.recoveryKeyChecksumMismatch {
            throw LumeCloudAccountError.recoveryKeyTypo
        } catch {
            throw LumeCloudAccountError.invalidRecoveryKey
        }
        let identity = LumeCloudIdentity(accountId: keys.accountId, rootKey: keys.rootKey)
        let previous = keyStore.load()
        try await join(identity) {
            do {
                try await registerDevice(keys: keys, deviceID: settings.rotateDeviceID())
            } catch {
                if case let .identity(stored) = previous, stored != identity {
                    keyStore.save(stored)
                } else {
                    keyStore.clear()
                }
                if let error = error as? LumeCloudError, error == .badAuth || error == .accountDeleted {
                    throw LumeCloudAccountError.wrongRecoveryKey
                }
                throw error
            }
        }
    }

    /// The account this device was last part of, from the keychain or the Lume
    /// Cloud store's bookkeeping. Nil when it never joined one.
    func lastKnownAccountId() -> String? {
        if let identity {
            return identity.accountId
        }
        if !isInert, case let .identity(stored) = keyStore.load() {
            return stored.accountId
        }
        let meta = try? ModelContext(container).fetch(FetchDescriptor<LumeCloudSyncMeta>()).first
        guard let accountId = meta?.accountId, !accountId.isEmpty else { return nil }
        return accountId
    }

    // MARK: Recovery key

    /// The joined account's recovery key. Never log it.
    func recoveryKey() throws -> String {
        guard let identity else { throw LumeCloudAccountError.notJoined }
        return try LumeCloudRecoveryKey.encode(rootKey: identity.rootKey)
    }

    func markRecoveryKeyViewed() {
        settings.recoveryKeyViewed = true
    }

    // MARK: Leave

    /// Leaves the account on this device: removes this device from the device
    /// list (best effort — offline, it lingers until someone removes it) and
    /// takes a fresh device id for a later rejoin. The keychain identity and the
    /// account stay, so rejoining needs no code.
    func leave() async {
        if let client = try? authenticatedClient() {
            do {
                try await client.revokeDevice(id: settings.deviceID)
            } catch {
                Logger.sync.notice("Lume Cloud leave: this device couldn't be removed from the device list")
            }
        }
        settings.rotateDeviceID()
        deactivate(state: .notJoined)
    }

    // MARK: Delete

    /// Deletes the account on the server, then drops the identity everywhere.
    /// Throws when the server can't be reached: a deletion is never queued.
    func deleteAccount() async throws {
        do {
            try await authenticatedClient().deleteAccount()
        } catch LumeCloudError.accountDeleted {
            // Already gone: the outcome the user asked for.
        }
        keyStore.clear()
        deactivate(state: .notJoined)
    }

    // MARK: Helpers

    /// A join replaces the account under the store, so it can't run while this
    /// backend is active and joined: the engine would reconcile against the
    /// emptied store with its old baseline.
    func ensureCanJoin() throws {
        guard !isInert else { throw LumeCloudAccountError.unavailable }
        guard !(isAttached && isJoined) else { throw LumeCloudAccountError.alreadyJoined }
    }

    /// Stores `identity` in the keychain first (so the key is never lost after
    /// the server knows the account), runs `register`, then activates with an
    /// empty store.
    private func join(_ identity: LumeCloudIdentity, register: () async throws -> Void) async throws {
        guard keyStore.save(identity) else { throw LumeCloudAccountError.keychainUnavailable }
        try await register()
        try await activate(identity, wipingStore: true)
        settings.recoveryKeyViewed = true
    }

    private func registerDevice(keys: LumeCloudKeys, deviceID: UUID) async throws {
        _ = try await makeClient(credentials(keys: keys, deviceID: deviceID))
            .registerDevice(id: deviceID, name: settings.deviceName, platform: .current)
    }

    /// Runs `body` with this device's id; when the server says that id was
    /// revoked (it can never register again), once more with a fresh one.
    func retryingRevokedDevice<Value>(_ body: (UUID) async throws -> Value) async throws -> Value {
        do {
            return try await body(settings.deviceID)
        } catch LumeCloudError.deviceRevoked {
            return try await body(settings.rotateDeviceID())
        }
    }

    /// The joined account's client, or `notJoined`.
    func authenticatedClient() throws -> any LumeCloudAccountAPI {
        guard !isInert else { throw LumeCloudAccountError.unavailable }
        guard let identity else { throw LumeCloudAccountError.notJoined }
        return try makeClient(credentials(keys: LumeCloudKeys(rootKey: identity.rootKey)))
    }

    /// Runs an authenticated call; a deleted account or a revoked device ends
    /// this device's membership as it would during a sync pass.
    func authenticated<Value>(_ body: (any LumeCloudAccountAPI) async throws -> Value) async throws -> Value {
        let client = try authenticatedClient()
        do {
            return try await body(client)
        } catch let error as LumeCloudError where error == .accountDeleted || error == .deviceRevoked {
            handleSyncError(error)
            throw error
        }
    }
}
