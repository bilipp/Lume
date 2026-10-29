//
//  LumeCloudBackendTestSupport.swift
//  LumeTests
//
//  Shared setup for the `LumeCloudBackend` suites: a backend over an in-memory
//  Lume Cloud store (`cloudKitDatabase: .none`), a throwaway defaults suite, its
//  own keychain service, and `StubLumeCloudAccountServer` instead of the network.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData

/// Records what a backend reports to the coordinator.
@MainActor
final class StubSyncBackendHost: SyncBackendHost {
    let status = CloudSyncStatus()
    private(set) var reconciles: [ReconcileReason] = []
    private(set) var settledCount = 0

    func reconcile(reason: ReconcileReason, debounced _: Bool) {
        reconciles.append(reason)
    }

    func backendDidSettleInitialSync() {
        settledCount += 1
    }
}

/// One simulated Apple ID's worth of Lume Cloud devices. Every device of a
/// fixture shares the keychain service, as iCloud Keychain would.
@MainActor
struct LumeCloudBackendFixture {
    let server = StubLumeCloudAccountServer()
    let keyStore: LumeCloudKeyStore

    init(keychainService: String) {
        keyStore = LumeCloudKeyStore(service: keychainService)
        keyStore.clear()
    }

    nonisolated static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "lumecloud.backend.tests.\(UUID().uuidString)")!
    }

    func makeBackend(
        defaults: UserDefaults = makeDefaults(),
        serverURL: URL = LumeCloudAPI.stagingURL,
        isInert: Bool = false
    ) throws -> LumeCloudBackend {
        try LumeCloudBackend(
            container: LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true),
            serverURL: serverURL,
            defaults: defaults,
            keyStore: keyStore,
            isInert: isInert,
            pairingPollInterval: .milliseconds(10),
            eventBackoff: LumeCloudEventListener.Backoff(initial: .milliseconds(5), maximum: .milliseconds(20)),
            makeClient: server.factory
        )
    }

    /// A backend that created an account.
    func makeJoinedBackend(defaults: UserDefaults = makeDefaults()) async throws -> (LumeCloudBackend, recoveryKey: String) {
        let backend = try makeBackend(defaults: defaults)
        let recoveryKey = try await backend.createAccount()
        return (backend, recoveryKey)
    }
}
