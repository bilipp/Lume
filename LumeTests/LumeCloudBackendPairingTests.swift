//
//  LumeCloudBackendPairingTests.swift
//  LumeTests
//
//  `LumeCloudBackend`'s pairing and device-list flows against
//  `StubLumeCloudAccountServer`: a new device joins through a code a joined
//  device confirms, expired codes and foreign servers are refused, and the
//  device list puts this device first and never revokes it. No network.
//

import Foundation
@testable import Lume
import LumeCloudKit
import Synchronization
import Testing

@MainActor
private final class PairingLog {
    var codes: [LumeCloudPairingCode] = []
    var pending: LumeCloudPendingDevice?
    var error: (any Error)?
}

/// Serialized: every test shares one keychain item.
@MainActor
@Suite(.serialized)
struct LumeCloudBackendPairingTests {
    private let fixture = LumeCloudBackendFixture(keychainService: "lume.cloud.tests.backend-pairing")

    private var server: StubLumeCloudAccountServer {
        fixture.server
    }

    /// Joins `newDevice` through a code `joinedDevice` looks up (typed with a
    /// space) and confirms.
    private func pair(_ newDevice: LumeCloudBackend, through joinedDevice: LumeCloudBackend) async throws -> PairingLog {
        let log = PairingLog()
        try await newDevice.joinWithPairingCode { code in
            log.codes.append(code)
            Task {
                do {
                    let typed = "\(code.code.prefix(3)) \(code.code.suffix(3))"
                    let pending = try await joinedDevice.lookUpPairing(code: typed)
                    log.pending = pending
                    try await joinedDevice.confirmPairing(pending)
                } catch {
                    log.error = error
                }
            }
        }
        return log
    }

    // MARK: Pairing

    @Test func `a new device joins through a code a joined device confirms`() async throws {
        let (joined, _) = try await fixture.makeJoinedBackend()
        let accountId = try #require(joined.identity?.accountId)
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let settings = LumeCloudSettings(defaults: defaults)
        settings.deviceName = "Den Screen"
        let newDevice = try fixture.makeBackend(defaults: defaults)

        let log = try await pair(newDevice, through: joined)

        #expect(log.error == nil)
        #expect(log.codes.count == 1)
        #expect(log.pending?.name == "Den Screen")
        #expect(log.pending?.platform == LumeCloudPlatform.current.rawValue)
        #expect(newDevice.isJoined)
        #expect(newDevice.identity == joined.identity)
        #expect(server.devices(of: accountId).contains { $0.id == settings.deviceID && $0.name == "Den Screen" })
    }

    @Test func `the pairing code links to the add-device flow`() {
        let code = LumeCloudPairingCode(code: "483920", expiresAt: .distantFuture)
        #expect(code.deepLink.absoluteString == "lume://cloud/pair?code=483920")
    }

    @Test func `an expired code stops the wait`() async throws {
        server.state.withLock { $0.pairingLifetime = -1000 }
        let newDevice = try fixture.makeBackend()
        await #expect(throws: LumeCloudAccountError.pairingExpired) {
            try await newDevice.joinWithPairingCode { _ in }
        }
        #expect(!newDevice.isJoined)
    }

    @Test func `cancelling the wait stops polling`() async throws {
        let newDevice = try fixture.makeBackend()
        let task = Task { try await newDevice.joinWithPairingCode { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!newDevice.isJoined)
    }

    @Test func `a grant for another server is refused`() async throws {
        let joined = try fixture.makeBackend(serverURL: LumeCloudAPI.officialURL)
        _ = try await joined.createAccount()
        fixture.keyStore.clear()
        let newDevice = try fixture.makeBackend(serverURL: LumeCloudAPI.stagingURL)

        await #expect(throws: LumeCloudAccountError.serverMismatch) {
            _ = try await pair(newDevice, through: joined)
        }
        #expect(!newDevice.isJoined)
        #expect(fixture.keyStore.load() == .notSet)
    }

    @Test func `looking up an unknown code reports it expired`() async throws {
        let (joined, _) = try await fixture.makeJoinedBackend()
        await #expect(throws: LumeCloudAccountError.pairingExpired) {
            try await joined.lookUpPairing(code: "000000")
        }
    }

    @Test func `adding a device needs a joined account`() async throws {
        let backend = try fixture.makeBackend()
        await #expect(throws: LumeCloudAccountError.notJoined) {
            try await backend.lookUpPairing(code: "483920")
        }
    }

    @Test(arguments: [
        ("483920", "483920"), ("483 920", "483920"), ("48-39-20", "483920"), (" 483920\n", "483920")
    ])
    func `pairing codes drop spaces and separators`(input: String, expected: String) throws {
        #expect(try LumeCloudBackend.normalizedPairingCode(input) == expected)
    }

    @Test(arguments: ["48392", "4839201", "48392a", "", "\u{0664}\u{0668}\u{0663}\u{0669}\u{0662}\u{0660}"])
    func `pairing codes other than six Western digits are rejected`(input: String) {
        #expect(throws: LumeCloudAccountError.invalidPairingCode) {
            try LumeCloudBackend.normalizedPairingCode(input)
        }
    }

    // MARK: Devices

    @Test func `the device list puts this device first and hides revoked ones`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let (backend, _) = try await fixture.makeJoinedBackend(defaults: defaults)
        let accountId = try #require(backend.identity?.accountId)
        let older = Device(id: UUID(), name: "Porch Tablet", platform: .android, createdAt: 0, lastSeen: 1000, revoked: false)
        let newer = Device(id: UUID(), name: "Loft TV", platform: .androidTV, createdAt: 0, lastSeen: 9_000_000_000_000, revoked: false)
        let revoked = Device(id: UUID(), name: "Shed", platform: .macOS, createdAt: 0, lastSeen: 5000, revoked: true)
        for device in [older, newer, revoked] {
            server.addDevice(device, to: accountId)
        }

        let devices = try await backend.devices()

        #expect(devices.map(\.id) == [LumeCloudSettings(defaults: defaults).deviceID, newer.id, older.id])
        #expect(devices.map(\.isCurrent) == [true, false, false])
        #expect(devices[1].platform == "androidtv")
        #expect(devices[2].lastSeen == Date(timeIntervalSince1970: 1))
    }

    @Test func `another device can be revoked, this one never`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let (backend, _) = try await fixture.makeJoinedBackend(defaults: defaults)
        let accountId = try #require(backend.identity?.accountId)
        let other = Device(id: UUID(), name: "Porch Tablet", platform: .android, createdAt: 0, lastSeen: 0, revoked: false)
        server.addDevice(other, to: accountId)

        try await backend.revokeDevice(id: other.id)
        await #expect(throws: LumeCloudAccountError.cannotRevokeCurrentDevice) {
            try await backend.revokeDevice(id: LumeCloudSettings(defaults: defaults).deviceID)
        }

        let stored = server.devices(of: accountId)
        #expect(stored.first { $0.id == other.id }?.revoked == true)
        #expect(stored.first { $0.id == LumeCloudSettings(defaults: defaults).deviceID }?.revoked == false)
    }
}
