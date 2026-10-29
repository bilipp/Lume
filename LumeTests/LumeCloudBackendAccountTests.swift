//
//  LumeCloudBackendAccountTests.swift
//  LumeTests
//
//  `LumeCloudBackend`'s account flows against `StubLumeCloudAccountServer`:
//  create, join with an empty store, restore from a recovery key, leave, delete,
//  and the inert `-ui-testing` mode. No network.
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
struct LumeCloudBackendAccountTests {
    private let fixture = LumeCloudBackendFixture(keychainService: "lume.cloud.tests.backend-account")

    private var server: StubLumeCloudAccountServer {
        fixture.server
    }

    // MARK: Create

    @Test func `create account stores the identity, registers this device and returns the recovery key`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let settings = LumeCloudSettings(defaults: defaults)
        settings.deviceName = "Lantern Room"
        let backend = try fixture.makeBackend(defaults: defaults)

        let recoveryKey = try await backend.createAccount()

        let identity = try #require(backend.identity)
        #expect(backend.isJoined)
        #expect(fixture.keyStore.load() == .identity(identity))
        #expect(try LumeCloudRecoveryKey.decode(recoveryKey) == identity.rootKey)
        #expect(try backend.recoveryKey() == recoveryKey)
        #expect(!settings.recoveryKeyViewed)
        let devices = server.devices(of: identity.accountId)
        #expect(devices.map(\.id) == [settings.deviceID])
        #expect(devices.first?.name == "Lantern Room")
        #expect(devices.first?.platform == .current)
    }

    @Test func `create account derives the account id from the root key`() async throws {
        let (backend, recoveryKey) = try await fixture.makeJoinedBackend()
        let identity = try #require(backend.identity)
        let keys = try LumeCloudRecoveryKey.keys(from: recoveryKey)
        #expect(identity.accountId == keys.accountId)
        #expect(identity.accountId.count == 22)
        #expect(server.devices(of: keys.accountId).count == 1)
    }

    @Test func `creating an account that already exists is refused`() async throws {
        let keys = LumeCloudKeys.generate()
        let client = server.factory(nil)
        let created = try await client.createAccount(keys: keys)
        #expect(created.accountId == keys.accountId)
        await #expect(throws: LumeCloudError.accountExists) {
            try await client.createAccount(keys: keys)
        }
    }

    @Test func `viewing the recovery key clears the not-viewed flag`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let (backend, _) = try await fixture.makeJoinedBackend(defaults: defaults)
        backend.markRecoveryKeyViewed()
        #expect(LumeCloudSettings(defaults: defaults).recoveryKeyViewed)
    }

    @Test func `joining an existing account leaves no recovery-key badge`() async throws {
        let (first, _) = try await fixture.makeJoinedBackend()
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let second = try fixture.makeBackend(defaults: defaults)

        try await second.join(#require(first.identity))

        #expect(LumeCloudSettings(defaults: defaults).recoveryKeyViewed)
    }

    @Test func `joining starts the Lume Cloud store and its shadow empty`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let backend = try fixture.makeBackend(defaults: defaults)
        let context = ModelContext(backend.container)
        context.insert(UserProfile(name: "Old Session"))
        context.insert(LumeCloudRecordState(rid: "rid-old", logicalKey: "profile/old", type: "profile", version: 4))
        context.insert(LumeCloudSyncMeta(nextSeq: 42, accountId: "acct-old"))
        try context.save()
        defaults.set(Data([1]), forKey: "cloudsync.lumecloud.shadow.playlists.v1")
        defaults.set(Data([2]), forKey: "cloudsync.shadow.playlists.v1")

        _ = try await backend.createAccount()

        let fresh = ModelContext(backend.container)
        #expect(try fresh.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<LumeCloudRecordState>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<LumeCloudSyncMeta>()) == 0)
        #expect(defaults.data(forKey: "cloudsync.lumecloud.shadow.playlists.v1") == nil)
        #expect(defaults.data(forKey: "cloudsync.shadow.playlists.v1") == Data([2]))
    }

    @Test func `joining while this backend is active and joined is refused`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        await #expect(throws: LumeCloudAccountError.alreadyJoined) {
            try await backend.createAccount()
        }
    }

    @Test func `a closed signup passes the server error through`() async throws {
        let backend = try fixture.makeBackend()
        server.failure.withLock { $0 = .signupClosed }
        await #expect(throws: LumeCloudError.signupClosed) {
            try await backend.createAccount()
        }
        #expect(!backend.isJoined)
        #expect(fixture.keyStore.load() == .notSet)
    }

    // MARK: Restore

    @Test func `restore joins the account a recovery key belongs to`() async throws {
        let (first, recoveryKey) = try await fixture.makeJoinedBackend()
        let accountId = try #require(first.identity?.accountId)
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let second = try fixture.makeBackend(defaults: defaults)

        try await second.restore(recoveryKey: recoveryKey.lowercased())

        #expect(second.identity == first.identity)
        #expect(LumeCloudSettings(defaults: defaults).recoveryKeyViewed)
        #expect(server.devices(of: accountId).count == 2)
    }

    @Test func `restore takes a fresh device id, empties the store and pulls from zero`() async throws {
        let (first, recoveryKey) = try await fixture.makeJoinedBackend()
        let accountId = try #require(first.identity?.accountId)
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let oldID = LumeCloudSettings(defaults: defaults).deviceID
        let second = try fixture.makeBackend(defaults: defaults)
        let context = ModelContext(second.container)
        context.insert(UserProfile(name: "Old Session"))
        context.insert(LumeCloudRecordState(rid: "rid-old", logicalKey: "profile/old", type: "profile", version: 4))
        context.insert(LumeCloudSyncMeta(nextSeq: 42, accountId: accountId))
        try context.save()
        defaults.set(Data([1]), forKey: "cloudsync.lumecloud.shadow.playlists.v1")

        try await second.restore(recoveryKey: recoveryKey)

        let newID = LumeCloudSettings(defaults: defaults).deviceID
        #expect(newID != oldID)
        #expect(server.devices(of: accountId).contains { $0.id == newID && !$0.revoked })
        #expect(!server.devices(of: accountId).contains { $0.id == oldID })
        let fresh = ModelContext(second.container)
        #expect(try fresh.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<LumeCloudRecordState>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<LumeCloudSyncMeta>()) == 0)
        #expect(defaults.data(forKey: "cloudsync.lumecloud.shadow.playlists.v1") == nil)

        try await second.pull()

        #expect(server.feed.requestedSince == [0])
    }

    @Test func `a rejected recovery key leaves no identity behind`() async throws {
        let backend = try fixture.makeBackend()
        let foreign = LumeCloudRecoveryKey.encode(LumeCloudKeys.generate())

        await #expect(throws: LumeCloudAccountError.wrongRecoveryKey) {
            try await backend.restore(recoveryKey: foreign)
        }

        #expect(!backend.isJoined)
        #expect(fixture.keyStore.load() == .notSet)
    }

    @Test func `a restore that loses the connection puts the previous identity back`() async throws {
        let (first, _) = try await fixture.makeJoinedBackend()
        let previous = try #require(first.identity)
        let second = try fixture.makeBackend()
        let otherAccount = LumeCloudRecoveryKey.encode(LumeCloudKeys.generate())
        server.failure.withLock { $0 = .transport(URLError(.notConnectedToInternet)) }

        await #expect(throws: LumeCloudError.self) {
            try await second.restore(recoveryKey: otherAccount)
        }

        // Both backends share the fixture's keychain, so the second one already
        // sees the first one's identity; the restore must leave it untouched.
        let restoredAccountId = try LumeCloudRecoveryKey.keys(from: otherAccount).accountId
        #expect(second.identity?.accountId != restoredAccountId)
        #expect(fixture.keyStore.load() == .identity(previous))
    }

    @Test func `restore tells a typo, a malformed key and another account's key apart`() async throws {
        let (first, recoveryKey) = try await fixture.makeJoinedBackend()
        let second = try fixture.makeBackend()

        var typo = Array(recoveryKey)
        typo[0] = typo[0] == "A" ? "B" : "A"
        await #expect(throws: LumeCloudAccountError.recoveryKeyTypo) {
            try await second.restore(recoveryKey: String(typo))
        }
        await #expect(throws: LumeCloudAccountError.invalidRecoveryKey) {
            try await second.restore(recoveryKey: "not-a-key")
        }
        let foreign = LumeCloudRecoveryKey.encode(LumeCloudKeys.generate())
        await #expect(throws: LumeCloudAccountError.wrongRecoveryKey) {
            try await second.restore(recoveryKey: foreign)
        }
        #expect(try fixture.keyStore.load() == .identity(#require(first.identity)))
    }

    @Test func `a revoked device id is replaced before joining again`() async throws {
        let (first, recoveryKey) = try await fixture.makeJoinedBackend()
        let accountId = try #require(first.identity?.accountId)
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let revokedID = LumeCloudSettings(defaults: defaults).deviceID
        server.addDevice(
            Device(id: revokedID, name: "Attic", platform: .iOS, createdAt: 0, lastSeen: 0, revoked: true),
            to: accountId
        )
        let second = try fixture.makeBackend(defaults: defaults)

        try await second.restore(recoveryKey: recoveryKey)

        let newID = LumeCloudSettings(defaults: defaults).deviceID
        #expect(newID != revokedID)
        #expect(server.devices(of: accountId).contains { $0.id == newID && !$0.revoked })
    }

    // MARK: Leave

    @Test func `leave removes this device, takes a fresh id and keeps the identity`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let (backend, _) = try await fixture.makeJoinedBackend(defaults: defaults)
        let identity = try #require(backend.identity)
        let oldID = LumeCloudSettings(defaults: defaults).deviceID

        await backend.leave()

        #expect(!backend.isJoined)
        #expect(LumeCloudSettings(defaults: defaults).deviceID != oldID)
        #expect(server.devices(of: identity.accountId).first { $0.id == oldID }?.revoked == true)
        #expect(fixture.keyStore.load() == .identity(identity))
        #expect(!server.isDeleted(identity.accountId))
    }

    @Test func `leave offline still leaves this device`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        server.failure.withLock { $0 = .transport(URLError(.notConnectedToInternet)) }
        await backend.leave()
        #expect(!backend.isJoined)
    }

    // MARK: Delete

    @Test func `delete account deletes it on the server and clears the keychain`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let accountId = try #require(backend.identity?.accountId)

        try await backend.deleteAccount()

        #expect(server.isDeleted(accountId))
        #expect(fixture.keyStore.load() == .notSet)
        #expect(!backend.isJoined)
    }

    @Test func `delete account offline throws and keeps the account`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        let identity = try #require(backend.identity)
        server.failure.withLock { $0 = .transport(URLError(.notConnectedToInternet)) }

        await #expect(throws: LumeCloudError.self) {
            try await backend.deleteAccount()
        }

        #expect(backend.isJoined)
        #expect(fixture.keyStore.load() == .identity(identity))
    }

    // MARK: Inert

    @Test func `an inert backend never touches the network or the keychain`() async throws {
        let (_, recoveryKey) = try await fixture.makeJoinedBackend()
        let callsBefore = server.calls.count
        let backend = try fixture.makeBackend(isInert: true)
        backend.attach(to: StubSyncBackendHost())

        #expect(!backend.isJoined)
        await #expect(throws: LumeCloudAccountError.unavailable) { try await backend.createAccount() }
        await #expect(throws: LumeCloudAccountError.unavailable) {
            try await backend.restore(recoveryKey: recoveryKey)
        }
        await #expect(throws: LumeCloudAccountError.unavailable) { try await backend.devices() }
        await #expect(throws: LumeCloudAccountError.unavailable) {
            try await backend.joinWithPairingCode { _ in }
        }
        try await backend.pull()
        try await backend.push()
        #expect(server.calls.count == callsBefore)
    }
}
