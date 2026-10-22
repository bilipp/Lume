//
//  SyncedBackendChoiceWatcherTests.swift
//  LumeTests
//
//  `SyncedBackendChoiceWatcher` over in-memory stores (`cloudKitDatabase:
//  .none`) and `StubLumeCloudAccountServer`: a device on iCloud follows the
//  Apple-wide choice into Lume Cloud only on its own server and never while
//  Off, the record's root key wins over the keychain, a Leave elsewhere sends
//  the account's devices back to iCloud, duplicates collapse to the newest
//  record, and this device's own switches write the record. No CloudKit, no
//  network.
//
//  The switches run real engine passes, which read the keychain PIN, so the
//  tests live in an extension of the `.serialized` `CloudSyncParentalEngineTests`
//  suite (see SyncBackendSwitchTests).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

@MainActor
private struct ChoiceHarness {
    nonisolated static let serverURL = LumeCloudAPI.stagingURL

    let catalog: ModelContainer
    /// The iCloud `CloudUserData` store: the mirror plus the record.
    let iCloudMirror: ModelContainer
    let defaults: UserDefaults
    let fixture = LumeCloudBackendFixture(keychainService: "lume.cloud.tests.backend-choice")
    let iCloud: ICloudBackend

    init() throws {
        catalog = try makeTestContainer()
        iCloudMirror = try makeICloudMirrorTestContainer(extraModels: [SyncedBackendChoice.self])
        defaults = LumeCloudBackendFixture.makeDefaults()
        iCloud = ICloudBackend(mirrorContainer: iCloudMirror, cloudKitContainerIdentifier: "iCloud.test.choice", cloudKitEnabled: false)
    }

    struct Device {
        let coordinator: CloudSyncCoordinator
        let lumeCloud: LumeCloudBackend
        let watcher: SyncedBackendChoiceWatcher
    }

    /// This device, starting on `start` (iCloud when nil; `lumeCloud` when it's
    /// already a joined Lume Cloud backend to start on).
    func makeDevice(
        start: (any SyncBackend)? = nil,
        lumeCloud existing: LumeCloudBackend? = nil,
        isEnabled: Bool = true
    ) throws -> Device {
        let lumeCloud = try existing ?? fixture.makeBackend(defaults: defaults)
        let coordinator = CloudSyncCoordinator(
            catalogContainer: catalog,
            cloudContainer: iCloudMirror,
            backend: start ?? iCloud,
            iCloudBackend: iCloud,
            makeLumeCloudBackend: { lumeCloud },
            defaults: defaults
        )
        let watcher = SyncedBackendChoiceWatcher(
            coordinator: coordinator,
            container: iCloudMirror,
            isEnabled: isEnabled,
            serverURL: Self.serverURL,
            keyStore: fixture.keyStore
        )
        return Device(coordinator: coordinator, lumeCloud: lumeCloud, watcher: watcher)
    }

    /// An account another device of this Apple ID created; it lands in the
    /// shared keychain as iCloud Keychain would carry it.
    func otherDevicesAccount() async throws -> LumeCloudIdentity {
        let (other, _) = try await fixture.makeJoinedBackend()
        return try #require(other.identity)
    }

    func insertChoice(
        _ backend: SyncedBackendChoice.Backend,
        serverURL: URL? = ChoiceHarness.serverURL,
        identity: LumeCloudIdentity? = nil,
        accountId: String? = nil,
        changedAt: Date = Date()
    ) throws {
        let context = ModelContext(iCloudMirror)
        context.insert(SyncedBackendChoice(
            backend: backend,
            serverURL: serverURL?.absoluteString ?? "",
            accountId: accountId ?? identity?.accountId ?? "",
            rootKey: identity?.rootKey,
            changedAt: changedAt
        ))
        try context.save()
    }

    func choices() throws -> [SyncedBackendChoice] {
        try ModelContext(iCloudMirror).fetch(FetchDescriptor<SyncedBackendChoice>())
    }
}

/// Runs one more pass and waits for it, so no switch's pass outlives the test.
@MainActor
private func settle(_ coordinator: CloudSyncCoordinator) async throws {
    coordinator.status.lastReconcile = nil
    coordinator.reconcile(reason: .queued, debounced: false)
    for _ in 0 ..< 200 where coordinator.status.lastReconcile == nil {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(coordinator.status.lastReconcile != nil)
}

extension CloudSyncParentalEngineTests {
    @Test func `a device on iCloud joins the Lume Cloud account another Apple device chose`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: identity)
        let device = try harness.makeDevice()

        await device.watcher.start()
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(device.lumeCloud.identity == identity)
        #expect(LumeCloudSettings(defaults: harness.defaults).backend == .lumecloud)
        let deviceID = LumeCloudSettings(defaults: harness.defaults).deviceID
        #expect(harness.fixture.server.devices(of: identity.accountId).contains { $0.id == deviceID && !$0.revoked })
        #expect(try harness.choices().count == 1)
    }

    @Test func `overlapping refreshes both return once the join landed`() async throws {
        let harness = try ChoiceHarness()
        let device = try harness.makeDevice()
        await device.watcher.start()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: identity)

        async let first: Void = device.watcher.refresh()
        async let second: Void = device.watcher.refresh()
        _ = await (first, second)
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(device.lumeCloud.identity == identity)
    }

    @Test func `a choice made on another server is ignored`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, serverURL: LumeCloudAPI.officialURL, identity: identity)
        let device = try harness.makeDevice()

        await device.watcher.start()

        #expect(device.coordinator.selectedBackend == .icloud)
        #expect(harness.fixture.server.devices(of: identity.accountId).count == 1)
    }

    @Test func `a device set to Off is never joined`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: identity)
        let device = try harness.makeDevice(start: OffBackend())

        await device.watcher.start()

        #expect(device.coordinator.selectedBackend == .off)
        #expect(harness.fixture.server.devices(of: identity.accountId).count == 1)
    }

    @Test func `a disabled watcher never reads or writes the record`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: identity, changedAt: Date(timeIntervalSince1970: 1))
        try harness.insertChoice(.lumecloud, identity: identity, changedAt: Date(timeIntervalSince1970: 2))
        let device = try harness.makeDevice(isEnabled: false)

        await device.watcher.start()
        try await device.coordinator.switchBackend(to: .off)

        #expect(device.coordinator.selectedBackend == .off)
        #expect(try harness.choices().count == 2)
    }

    @Test func `duplicate records collapse to the newest`() async throws {
        let harness = try ChoiceHarness()
        let foreignServer = try #require(URL(string: "https://cloud.invalid"))
        try harness.insertChoice(.icloud, serverURL: nil, changedAt: Date(timeIntervalSince1970: 1000))
        try harness.insertChoice(.lumecloud, serverURL: foreignServer, accountId: "acct-newest", changedAt: Date(timeIntervalSince1970: 3000))
        try harness.insertChoice(.icloud, serverURL: nil, changedAt: Date(timeIntervalSince1970: 2000))
        let device = try harness.makeDevice()

        await device.watcher.start()

        let remaining = try harness.choices()
        #expect(remaining.count == 1)
        #expect(remaining.first?.accountId == "acct-newest")
        #expect(device.coordinator.selectedBackend == .icloud)
    }

    @Test func `the record's root key wins over the keychain`() async throws {
        let harness = try ChoiceHarness()
        let recorded = try await harness.otherDevicesAccount()
        // A later account overwrote the shared keychain item.
        let keychain = try await harness.otherDevicesAccount()
        #expect(harness.fixture.keyStore.load() == .identity(keychain))
        try harness.insertChoice(.lumecloud, identity: recorded)
        let device = try harness.makeDevice()

        await device.watcher.start()
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(device.lumeCloud.identity == recorded)
        #expect(harness.fixture.keyStore.load() == .identity(recorded))
    }

    @Test func `a record without its root key joins with the keychain's key for the same account`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, accountId: identity.accountId)
        let device = try harness.makeDevice()

        await device.watcher.start()
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(device.lumeCloud.identity == identity)
    }

    @Test func `leaving Lume Cloud elsewhere sends this device back to iCloud`() async throws {
        let harness = try ChoiceHarness()
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let identity = try #require(lumeCloud.identity)
        let deviceID = LumeCloudSettings(defaults: harness.defaults).deviceID
        let device = try harness.makeDevice(start: lumeCloud, lumeCloud: lumeCloud)
        try harness.insertChoice(.icloud, accountId: identity.accountId)
        let written = try #require(try harness.choices().first?.changedAt)

        await device.watcher.start()
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .icloud)
        #expect(LumeCloudSettings(defaults: harness.defaults).backend == .icloud)
        #expect(harness.fixture.server.devices(of: identity.accountId).first { $0.id == deviceID }?.revoked == true)
        #expect(try harness.choices().map(\.changedAt) == [written])
    }

    @Test func `leaving another account elsewhere keeps this device on Lume Cloud`() async throws {
        let harness = try ChoiceHarness()
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let device = try harness.makeDevice(start: lumeCloud, lumeCloud: lumeCloud)
        try harness.insertChoice(.icloud, accountId: "acct-elsewhere")

        await device.watcher.start()

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(lumeCloud.isJoined)
    }

    @Test func `a device on another account moves to the recorded one by way of iCloud`() async throws {
        let harness = try ChoiceHarness()
        let (lumeCloud, _) = try await harness.fixture.makeJoinedBackend(defaults: harness.defaults)
        let previous = try #require(lumeCloud.identity)
        let device = try harness.makeDevice(start: lumeCloud, lumeCloud: lumeCloud)
        let recorded = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: recorded)

        await device.watcher.start()
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(lumeCloud.identity == recorded)
        let leftDevices = harness.fixture.server.devices(of: previous.accountId)
        #expect(!leftDevices.isEmpty && leftDevices.allSatisfy(\.revoked))
        let choice = try #require(try harness.choices().first)
        #expect(choice.backend == SyncedBackendChoice.Backend.lumecloud.rawValue)
        #expect(choice.accountId == recorded.accountId)
    }

    @Test func `this device's switches write the choice, except Off`() async throws {
        let harness = try ChoiceHarness()
        let device = try harness.makeDevice()
        _ = try await device.lumeCloud.createAccount()
        let identity = try #require(device.lumeCloud.identity)

        try await device.coordinator.switchBackend(to: .lumecloud)
        try await settle(device.coordinator)

        var choice = try #require(try harness.choices().first)
        #expect(choice.backend == SyncedBackendChoice.Backend.lumecloud.rawValue)
        #expect(choice.serverURL == ChoiceHarness.serverURL.absoluteString)
        #expect(choice.accountId == identity.accountId)
        #expect(choice.rootKey == identity.rootKey)

        try await device.coordinator.switchBackend(to: .icloud)
        try await settle(device.coordinator)

        choice = try #require(try harness.choices().first)
        #expect(try harness.choices().count == 1)
        #expect(choice.backend == SyncedBackendChoice.Backend.icloud.rawValue)
        #expect(choice.accountId == identity.accountId)
        #expect(choice.rootKey == nil)
        let leftAt = choice.changedAt

        try await device.coordinator.switchBackend(to: .off)
        try await device.coordinator.switchBackend(to: .icloud)
        try await settle(device.coordinator)

        #expect(try harness.choices().map(\.changedAt) == [leftAt])
    }
}

// MARK: - Launch gate and moved notice

extension CloudSyncParentalEngineTests {
    @Test func `an auto-join at launch opens the launch gate once its first Lume Cloud pass lands`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: identity)
        let device = try harness.makeDevice()
        device.coordinator.status.hasCompletedInitialSync = false

        await device.watcher.start()
        try await settle(device.coordinator)

        #expect(device.coordinator.selectedBackend == .lumecloud)
        #expect(!device.coordinator.status.isAwaitingLaunchJoin)
        #expect(device.coordinator.status.isLaunchGateOpen)
    }

    @Test func `the launch-join hold outlasts iCloud passes and ends with the first Lume Cloud pass`() async throws {
        let harness = try ChoiceHarness()
        let device = try harness.makeDevice()
        _ = try await device.lumeCloud.createAccount()
        device.coordinator.status.hasCompletedInitialSync = false

        device.coordinator.beginLaunchJoinWait()
        try await settle(device.coordinator)

        #expect(device.coordinator.status.isAwaitingLaunchJoin)
        #expect(!device.coordinator.status.isLaunchGateOpen)

        try await device.coordinator.switchBackend(to: .lumecloud)
        try await settle(device.coordinator)

        #expect(!device.coordinator.status.isAwaitingLaunchJoin)
        #expect(device.coordinator.status.hasCompletedInitialSync)
    }

    @Test func `the launch-join hold never closes an open gate`() throws {
        let harness = try ChoiceHarness()
        let device = try harness.makeDevice()
        #expect(device.coordinator.status.hasCompletedInitialSync)

        device.coordinator.beginLaunchJoinWait()

        #expect(!device.coordinator.status.isAwaitingLaunchJoin)
        #expect(device.coordinator.status.isLaunchGateOpen)
    }

    @Test func `the launch-join hold opens the gate when its limit runs out`() async throws {
        let harness = try ChoiceHarness()
        let device = try harness.makeDevice()
        device.coordinator.status.hasCompletedInitialSync = false

        device.coordinator.beginLaunchJoinWait(limit: .milliseconds(20))
        #expect(device.coordinator.status.isAwaitingLaunchJoin)
        for _ in 0 ..< 200 where device.coordinator.status.isAwaitingLaunchJoin {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(device.coordinator.status.isLaunchGateOpen)
    }

    @Test func `a failed auto-join releases the hold and leaves the gate to iCloud`() async throws {
        let harness = try ChoiceHarness()
        let identity = try await harness.otherDevicesAccount()
        try harness.insertChoice(.lumecloud, identity: identity)
        let device = try harness.makeDevice()
        device.coordinator.status.hasCompletedInitialSync = false
        harness.fixture.server.failure.withLock { $0 = .transport(URLError(.notConnectedToInternet)) }

        await device.watcher.start()

        #expect(device.coordinator.selectedBackend == .icloud)
        #expect(!device.coordinator.status.isAwaitingLaunchJoin)
        #expect(!device.coordinator.status.hasCompletedInitialSync)
        #expect(!harness.defaults.bool(forKey: LumeCloudSettings.Key.movedNoticePending))
    }

    @Test func `only an auto-join queues the moved notice, and only until it was shown`() async throws {
        let harness = try ChoiceHarness()
        let own = try harness.makeDevice()
        _ = try await own.lumeCloud.createAccount()
        try await own.coordinator.switchBackend(to: .lumecloud)
        try await settle(own.coordinator)
        #expect(!harness.defaults.bool(forKey: LumeCloudSettings.Key.movedNoticePending))

        let followed = try ChoiceHarness()
        let identity = try await followed.otherDevicesAccount()
        try followed.insertChoice(.lumecloud, identity: identity)
        let device = try followed.makeDevice()
        await device.watcher.start()
        try await settle(device.coordinator)
        #expect(followed.defaults.bool(forKey: LumeCloudSettings.Key.movedNoticePending))

        followed.defaults.set(false, forKey: LumeCloudSettings.Key.movedNoticePending)
        followed.defaults.set(true, forKey: LumeCloudSettings.Key.movedNoticeShown)
        LumeCloudSettings(defaults: followed.defaults).queueMovedNotice()
        #expect(!followed.defaults.bool(forKey: LumeCloudSettings.Key.movedNoticePending))
    }
}
