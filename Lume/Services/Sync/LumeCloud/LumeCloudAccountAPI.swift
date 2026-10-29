import Foundation
import LumeCloudKit

/// Every Lume Cloud call `LumeCloudBackend` makes: the sync calls of
/// `LumeCloudSyncing` plus accounts, devices and pairing. A seam over
/// `LumeCloudClient` so the account flows are tested offline. Never retries.
nonisolated protocol LumeCloudAccountAPI: LumeCloudSyncing {
    func createAccount(keys: LumeCloudKeys) async throws -> AccountCreated
    func account() async throws -> AccountInfo
    func deleteAccount() async throws
    func registerDevice(id: UUID, name: String, platform: LumeCloudPlatform) async throws -> Device
    func devices() async throws -> [Device]
    func revokeDevice(id: UUID) async throws
    func startPairing(publicKey: String, deviceName: String, platform: LumeCloudPlatform) async throws -> PairingTicket
    func pairingRequest(code: String) async throws -> PairingRequest
    func sealPairing(code: String, sealed: SealedGrant) async throws
    func pairingResult(code: String, pollToken: String) async throws -> PairingPollResult
}

/// Builds a client for one set of credentials; `nil` for the unauthenticated
/// calls (account creation, the new device's side of pairing).
typealias LumeCloudClientFactory = @Sendable (LumeCloudClient.Credentials?) -> any LumeCloudAccountAPI

/// `LumeCloudAccountAPI` over the real server, sharing the sync transport's
/// ephemeral session.
nonisolated struct LiveLumeCloudAccountAPI: LumeCloudAccountAPI {
    private let client: LumeCloudClient
    private let socketClient: LumeCloudClient

    init(baseURL: URL, credentials: LumeCloudClient.Credentials?) {
        client = LumeCloudClient(baseURL: baseURL, session: LiveLumeCloudSyncing.session, credentials: credentials)
        socketClient = LumeCloudClient(baseURL: baseURL, session: LiveLumeCloudSyncing.socketSession, credentials: credentials)
    }

    static func factory(serverURL: URL) -> LumeCloudClientFactory {
        { credentials in LiveLumeCloudAccountAPI(baseURL: serverURL, credentials: credentials) }
    }

    func allChanges(since: Int, limit: Int?) async throws -> ChangesPage {
        try await client.allChanges(since: since, limit: limit)
    }

    func push(_ records: [PushRecord]) async throws -> PushResponse {
        try await client.push(records)
    }

    func changes(since: Int, limit: Int?) async throws -> ChangesPage {
        try await client.changes(since: since, limit: limit)
    }

    func events() -> AsyncThrowingStream<Int, Error> {
        socketClient.events()
    }

    func createAccount(keys: LumeCloudKeys) async throws -> AccountCreated {
        try await client.createAccount(keys: keys)
    }

    func account() async throws -> AccountInfo {
        try await client.account()
    }

    func deleteAccount() async throws {
        try await client.deleteAccount()
    }

    func registerDevice(id: UUID, name: String, platform: LumeCloudPlatform) async throws -> Device {
        try await client.registerDevice(id: id, name: name, platform: platform)
    }

    func devices() async throws -> [Device] {
        try await client.devices()
    }

    func revokeDevice(id: UUID) async throws {
        try await client.revokeDevice(id: id)
    }

    func startPairing(publicKey: String, deviceName: String, platform: LumeCloudPlatform) async throws -> PairingTicket {
        try await client.startPairing(publicKey: publicKey, deviceName: deviceName, platform: platform)
    }

    func pairingRequest(code: String) async throws -> PairingRequest {
        try await client.pairingRequest(code: code)
    }

    func sealPairing(code: String, sealed: SealedGrant) async throws {
        try await client.sealPairing(code: code, sealed: sealed)
    }

    func pairingResult(code: String, pollToken: String) async throws -> PairingPollResult {
        try await client.pairingResult(code: code, pollToken: pollToken)
    }
}
