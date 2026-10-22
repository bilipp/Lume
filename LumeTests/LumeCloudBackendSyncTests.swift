//
//  LumeCloudBackendSyncTests.swift
//  LumeTests
//
//  `LumeCloudBackend` as a `SyncBackend` against `StubLumeCloudAccountServer`:
//  launch, pull and push through the transport, the foreground pull gate, and
//  the status after a deleted account or a revoked device. No network.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

/// Serialized: every test shares one keychain item.
@MainActor
@Suite(.serialized)
struct LumeCloudBackendSyncTests {
    private let fixture = LumeCloudBackendFixture(keychainService: "lume.cloud.tests.backend-sync")
    private let profileID = UUID(uuidString: "3C4D5E6F-7A8B-4C9D-8E0F-1A2B3C4D5E6F")!

    private var server: StubLumeCloudAccountServer {
        fixture.server
    }

    private func keys(of backend: LumeCloudBackend) throws -> LumeCloudKeys {
        try LumeCloudKeys(rootKey: #require(backend.identity).rootKey)
    }

    @Test func `launch requests a pass when joined`() async throws {
        let (joined, _) = try await fixture.makeJoinedBackend()
        let backend = try fixture.makeBackend()
        let host = StubSyncBackendHost()
        backend.attach(to: host)

        await backend.start()

        #expect(joined.identity == backend.identity)
        #expect(backend.waitsForInitialSync)
        #expect(host.status.lumeCloud == .joined)
        #expect(host.reconciles == [.launch])
        #expect(host.settledCount == 0)
    }

    @Test func `launch without an account settles the gate at once`() async throws {
        let backend = try fixture.makeBackend()
        let host = StubSyncBackendHost()
        backend.attach(to: host)

        await backend.start()

        #expect(!backend.waitsForInitialSync)
        #expect(host.status.lumeCloud == .notJoined)
        #expect(host.reconciles.isEmpty)
        #expect(host.settledCount == 1)
        try await backend.pull()
    }

    @Test func `a pass pulls remote rows and pushes local ones`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        let keys = try keys(of: backend)
        let remoteProfile = UserProfile(id: profileID, name: "Harbor", createdAt: .now, updatedAt: .now)
        let (remoteRID, ciphertext) = try keys.seal(LumeCloudPayloadCodec.payload(for: remoteProfile, previous: nil))
        server.feed.store(rid: remoteRID, ciphertext: ciphertext)
        let localProfile = UserProfile(name: "Orchard")
        let context = ModelContext(backend.container)
        context.insert(localProfile)
        try context.save()

        #expect(backend.hasPendingChanges)
        try await backend.pull()
        #expect(!backend.hasPendingChanges)
        try await backend.push()

        let names = try ModelContext(backend.container).fetch(FetchDescriptor<UserProfile>()).map(\.name).sorted()
        #expect(names == ["Harbor", "Orchard"])
        let localRID = keys.recordID(for: "profile/\(localProfile.id.uuidString)")
        #expect(server.feed.state.withLock { $0.records[localRID] } != nil)
        #expect(host.status.lumeCloud == .joined)
        #expect(host.settledCount == 1)
    }

    @Test func `a deleted account ends this device's membership and clears the keychain`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let accountId = try #require(backend.identity?.accountId)
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        var ended: [LumeCloudAccountEnd] = []
        backend.onAccountEnded = { ended.append($0) }
        server.state.withLock { _ = $0.deletedAccounts.insert(accountId) }

        await #expect(throws: LumeCloudError.accountDeleted) {
            try await backend.pull()
        }

        #expect(ended == [.accountDeleted])
        #expect(host.status.lumeCloud == .accountDeleted)
        #expect(!backend.isJoined)
        #expect(fixture.keyStore.load() == .notSet)
        try await backend.push()
    }

    @Test func `a revoked device leaves alone and keeps the shared identity`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let (backend, _) = try await fixture.makeJoinedBackend(defaults: defaults)
        let identity = try #require(backend.identity)
        let deviceID = LumeCloudSettings(defaults: defaults).deviceID
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        var ended: [LumeCloudAccountEnd] = []
        backend.onAccountEnded = { ended.append($0) }
        server.state.withLock { $0.devices[identity.accountId]?[deviceID]?.revoked = true }

        await #expect(throws: LumeCloudError.deviceRevoked) {
            try await backend.pull()
        }

        #expect(ended == [.deviceRevoked])
        #expect(host.status.lumeCloud == .revoked)
        #expect(!backend.isJoined)
        #expect(LumeCloudSettings(defaults: defaults).deviceID != deviceID)
        #expect(fixture.keyStore.load() == .identity(identity))
    }

    @Test func `an offline pass reports offline and stays joined`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        server.failure.withLock { $0 = .transport(URLError(.notConnectedToInternet)) }

        await #expect(throws: LumeCloudError.self) {
            try await backend.pull()
        }

        #expect(host.status.lumeCloud == .offline)
        #expect(backend.isJoined)
    }

    @Test func `a stopped backend leaves the status alone`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        backend.stop()
        host.status.lumeCloud = .notJoined

        try await backend.pull()
        try await backend.push()

        #expect(host.status.lumeCloud == .notJoined)
    }
}
