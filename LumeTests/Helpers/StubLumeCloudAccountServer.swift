//
//  StubLumeCloudAccountServer.swift
//  LumeTests
//
//  An in-memory Lume Cloud server behind `LumeCloudAccountAPI`: accounts,
//  devices and pairing per PROTOCOL.md §2.2 and §4.1–4.5, with the change feed
//  delegated to a `StubLumeCloudClient`. Every authenticated call checks the
//  bearer token against the stored verifier, a deleted account answers
//  `account_deleted`, and a revoked device id answers `device_revoked`.
//

import CryptoKit
import Foundation
@testable import Lume
import LumeCloudKit
import Synchronization

final nonisolated class StubLumeCloudAccountServer: Sendable {
    struct Pairing {
        var publicKey: String
        var deviceName: String
        var platform: LumeCloudPlatform
        var pollToken: String
        var expiresAt: Int
        var sealed: SealedGrant?
    }

    struct State {
        var verifiers: [String: String] = [:]
        var deletedAccounts: Set<String> = []
        var devices: [String: [UUID: Device]] = [:]
        var pairings: [String: Pairing] = [:]
        var nextCode = 483_920
        /// Every call, by name, in order.
        var calls: [String] = []
        /// How long a new pairing code stays valid, in milliseconds.
        var pairingLifetime = 600_000
    }

    let state = Mutex(State())
    /// When set, every request fails with this error before reaching the server.
    let failure = Mutex<LumeCloudError?>(nil)
    let feed = StubLumeCloudClient(keys: LumeCloudKeys.generate())

    var factory: LumeCloudClientFactory {
        { [self] credentials in Client(server: self, credentials: credentials) }
    }

    var calls: [String] {
        state.withLock(\.calls)
    }

    func devices(of accountId: String) -> [Device] {
        state.withLock { Array(($0.devices[accountId] ?? [:]).values) }
    }

    func isDeleted(_ accountId: String) -> Bool {
        state.withLock { $0.deletedAccounts.contains(accountId) }
    }

    /// Adds a device to `accountId` directly, as another member would.
    func addDevice(_ device: Device, to accountId: String) {
        state.withLock { $0.devices[accountId, default: [:]][device.id] = device }
    }

    static func verifier(forToken token: String) -> String? {
        guard let authKey = Base64URL.decode(token) else { return nil }
        return Base64URL.encode(Data(SHA256.hash(data: authKey)))
    }

    nonisolated struct Client: LumeCloudAccountAPI {
        let server: StubLumeCloudAccountServer
        let credentials: LumeCloudClient.Credentials?

        private func log(_ call: String) throws {
            server.state.withLock { $0.calls.append(call) }
            if let failure = server.failure.withLock({ $0 }) {
                throw failure
            }
        }

        /// The account the credentials authenticate, per PROTOCOL.md §2.2.
        @discardableResult
        private func authorize(checkDevice: Bool = true) throws -> String {
            guard let credentials else { throw LumeCloudError.missingCredentials }
            return try server.state.withLock { state in
                if state.deletedAccounts.contains(credentials.accountId) {
                    throw LumeCloudError.accountDeleted
                }
                guard let stored = state.verifiers[credentials.accountId],
                      stored == StubLumeCloudAccountServer.verifier(forToken: credentials.authToken)
                else { throw LumeCloudError.badAuth }
                if checkDevice, state.devices[credentials.accountId]?[credentials.deviceID]?.revoked == true {
                    throw LumeCloudError.deviceRevoked
                }
                return credentials.accountId
            }
        }

        func allChanges(since: Int, limit: Int?) async throws -> ChangesPage {
            try log("allChanges")
            try authorize()
            return try await server.feed.allChanges(since: since, limit: limit)
        }

        func push(_ records: [PushRecord]) async throws -> PushResponse {
            try log("push")
            try authorize()
            return try await server.feed.push(records)
        }

        func changes(since: Int, limit: Int?) async throws -> ChangesPage {
            try log("changes")
            try authorize()
            return try await server.feed.changes(since: since, limit: limit)
        }

        /// A refused upgrade carries no body: 401 reads as `.badAuth`, 404 as
        /// `.notFound` (PROTOCOL.md §4.6).
        func events() -> AsyncThrowingStream<Int, Error> {
            do {
                try log("events")
                try authorize()
            } catch {
                let refused: Error = switch error as? LumeCloudError {
                case .accountDeleted: LumeCloudError.notFound
                case .deviceRevoked, .badAuth: LumeCloudError.badAuth
                default: error
                }
                return AsyncThrowingStream { $0.finish(throwing: refused) }
            }
            return server.feed.events()
        }

        /// The id is derived from the root key; a live account under it answers
        /// `account_exists`, a deleted one can be created again (PROTOCOL.md §4.1, §4.8).
        func createAccount(keys: LumeCloudKeys) async throws -> AccountCreated {
            try log("createAccount")
            let accountId = keys.accountId
            return try server.state.withLock { state in
                if state.verifiers[accountId] != nil, !state.deletedAccounts.contains(accountId) {
                    throw LumeCloudError.accountExists
                }
                state.deletedAccounts.remove(accountId)
                state.devices[accountId] = nil
                state.verifiers[accountId] = keys.authVerifier
                return AccountCreated(accountId: accountId, createdAt: 1_760_000_000_000)
            }
        }

        func account() async throws -> AccountInfo {
            try log("account")
            let accountId = try authorize()
            let nextSeq = server.feed.state.withLock(\.lastSeq) + 1
            return AccountInfo(accountId: accountId, createdAt: 1_760_000_000_000, usedBytes: 0, recordCount: 0, nextSeq: nextSeq)
        }

        func deleteAccount() async throws {
            try log("deleteAccount")
            let accountId = try authorize()
            server.state.withLock { _ = $0.deletedAccounts.insert(accountId) }
        }

        func registerDevice(id: UUID, name: String, platform: LumeCloudPlatform) async throws -> Device {
            try log("registerDevice")
            let accountId = try authorize(checkDevice: false)
            return try server.state.withLock { state in
                if state.devices[accountId]?[id]?.revoked == true {
                    throw LumeCloudError.deviceRevoked
                }
                let device = Device(
                    id: id, name: name, platform: platform,
                    createdAt: 1_760_000_000_000, lastSeen: 1_760_000_000_000, revoked: false
                )
                state.devices[accountId, default: [:]][id] = device
                return device
            }
        }

        func devices() async throws -> [Device] {
            try log("devices")
            let accountId = try authorize()
            return server.devices(of: accountId)
        }

        func revokeDevice(id: UUID) async throws {
            try log("revokeDevice")
            let accountId = try authorize()
            try server.state.withLock { state in
                guard state.devices[accountId]?[id] != nil else { throw LumeCloudError.notFound }
                state.devices[accountId]?[id]?.revoked = true
            }
        }

        func startPairing(publicKey: String, deviceName: String, platform: LumeCloudPlatform) async throws -> PairingTicket {
            try log("startPairing")
            return server.state.withLock { state in
                let code = String(state.nextCode)
                state.nextCode += 1
                let expiresAt = Int(Date().timeIntervalSince1970 * 1000) + state.pairingLifetime
                let pollToken = "poll-\(code)"
                state.pairings[code] = Pairing(
                    publicKey: publicKey, deviceName: deviceName, platform: platform,
                    pollToken: pollToken, expiresAt: expiresAt
                )
                return PairingTicket(code: code, pollToken: pollToken, expiresAt: expiresAt)
            }
        }

        func pairingRequest(code: String) async throws -> PairingRequest {
            try log("pairingRequest")
            try authorize()
            return try server.state.withLock { state in
                guard let pairing = state.pairings[code] else { throw LumeCloudError.notFound }
                return PairingRequest(
                    publicKey: pairing.publicKey, deviceName: pairing.deviceName,
                    platform: pairing.platform, expiresAt: pairing.expiresAt
                )
            }
        }

        func sealPairing(code: String, sealed: SealedGrant) async throws {
            try log("sealPairing")
            try authorize()
            try server.state.withLock { state in
                guard let pairing = state.pairings[code] else { throw LumeCloudError.notFound }
                guard pairing.sealed == nil else { throw LumeCloudError.pairingAlreadySealed }
                state.pairings[code]?.sealed = sealed
            }
        }

        func pairingResult(code: String, pollToken: String) async throws -> PairingPollResult {
            try log("pairingResult")
            return try server.state.withLock { state in
                guard let pairing = state.pairings[code], pairing.pollToken == pollToken else {
                    throw LumeCloudError.notFound
                }
                guard let sealed = pairing.sealed else { return .pending }
                state.pairings[code] = nil
                return .sealed(sealed)
            }
        }
    }
}
