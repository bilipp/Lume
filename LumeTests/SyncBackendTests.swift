import Foundation
@testable import Lume
import SwiftData
import Testing

/// A scripted backend: records the pass phases the coordinator drives.
@MainActor
private final class StubSyncBackend: SyncBackend {
    struct PullFailure: Error {}

    let kind: SyncBackendKind? = .lumecloud
    let mirrorContainer: ModelContainer?
    let waitsForInitialSync: Bool
    var hasPendingChanges = false
    var failPull = false
    /// While set, `pull()` suspends, keeping the pass in flight.
    var holdPull = false
    private(set) var calls: [String] = []
    private(set) weak var host: (any SyncBackendHost)?

    init(mirrorContainer: ModelContainer, waitsForInitialSync: Bool = false) {
        self.mirrorContainer = mirrorContainer
        self.waitsForInitialSync = waitsForInitialSync
    }

    func attach(to host: any SyncBackendHost) {
        self.host = host
    }

    func start() async {
        calls.append("start")
    }

    func refreshStatus() async {}

    func pull() async throws {
        calls.append("pull")
        while holdPull {
            try? await Task.sleep(for: .milliseconds(10))
        }
        hasPendingChanges = false
        if failPull { throw PullFailure() }
    }

    func push() async throws {
        calls.append("push")
    }

    func stop() {
        host = nil
    }

    func record(_ event: String) {
        calls.append(event)
    }
}

/// The coordinator as a facade over `SyncBackend`: pass order, the pending-flag
/// gate on foreground / remote-change passes, Off, and the launch gate.
@MainActor
struct SyncBackendFacadeTests {
    private func waitForReconcile(_ coordinator: CloudSyncCoordinator, attempts: Int = 100) async -> Date? {
        for _ in 0 ..< attempts {
            if let date = coordinator.status.lastReconcile { return date }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test func `a pass runs pull, then reconcile, then push`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)
        #expect(backend.host === coordinator)

        coordinator.reconcile(reason: .queued, debounced: false)

        #expect(await waitForReconcile(coordinator) != nil)
        #expect(backend.calls == ["pull", "push"])
    }

    @Test func `a failed pull still reconciles and pushes`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container)
        backend.failPull = true
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)

        coordinator.reconcile(reason: .queued, debounced: false)

        #expect(await waitForReconcile(coordinator) != nil)
        #expect(backend.calls == ["pull", "push"])
    }

    @Test func `foreground passes wait for pending remote changes`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)

        coordinator.reconcile(reason: .foreground, debounced: false)
        coordinator.reconcile(reason: .remoteChange, debounced: false)
        #expect(await waitForReconcile(coordinator, attempts: 10) == nil)
        #expect(backend.calls.isEmpty)

        backend.hasPendingChanges = true
        coordinator.reconcile(reason: .foreground, debounced: false)
        #expect(await waitForReconcile(coordinator) != nil)
        #expect(backend.calls == ["pull", "push"])
        #expect(!backend.hasPendingChanges)
    }

    @Test func `sync now runs a full pass even with nothing pending`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)
        #expect(!backend.hasPendingChanges)

        await coordinator.syncNow()

        #expect(backend.calls == ["pull", "push"])
        #expect(coordinator.status.lastReconcile != nil)
        #expect(!coordinator.isSyncingNow)
    }

    @Test func `start is delegated to the backend`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)

        await coordinator.start()

        #expect(backend.calls == ["start"])
    }

    @Test func `the launch gate opens after the pass that follows settling`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container, waitsForInitialSync: true)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)
        #expect(!coordinator.status.hasCompletedInitialSync)

        backend.host?.backendDidSettleInitialSync()

        for _ in 0 ..< 100 where !coordinator.status.hasCompletedInitialSync {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(coordinator.status.hasCompletedInitialSync)
        #expect(backend.calls == ["pull", "push"])
    }

    @Test func `sync turned off never reconciles and never holds the launch gate`() async throws {
        let container = try makeTestContainer()
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: OffBackend())
        #expect(coordinator.status.hasCompletedInitialSync)
        #expect(coordinator.backend.kind == nil)

        await coordinator.start()
        coordinator.reconcile(reason: .backgroundFlush, debounced: false)
        coordinator.reconcile(reason: .launch, debounced: false)

        #expect(await waitForReconcile(coordinator, attempts: 10) == nil)
    }

    @Test func `an inert iCloud backend reconciles the local store without waiting`() async throws {
        let container = try makeTestContainer()
        let backend = ICloudBackend(mirrorContainer: container, cloudKitContainerIdentifier: "iCloud.test", cloudKitEnabled: false)
        #expect(backend.kind == .icloud)
        #expect(!backend.waitsForInitialSync)
        #expect(!backend.hasPendingChanges)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)

        await coordinator.start()

        #expect(await waitForReconcile(coordinator) != nil)
    }
}

/// `replaceEngine` waits out the in-flight pass and queues passes requested
/// meanwhile, so the old and the new engine never reconcile at once.
@MainActor
struct CloudSyncEngineSwapTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func `the engine starts in the backend's namespace`() throws {
        let container = try makeTestContainer()
        let iCloud = CloudSyncCoordinator(
            catalogContainer: container,
            cloudContainer: container,
            backend: ICloudBackend(mirrorContainer: container, cloudKitContainerIdentifier: "iCloud.test", cloudKitEnabled: false)
        )
        let lumeCloud = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: StubSyncBackend(mirrorContainer: container))
        let off = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: OffBackend())

        #expect(iCloud.engineNamespace == .icloud)
        #expect(lumeCloud.engineNamespace == .lumecloud)
        #expect(off.engineNamespace == .icloud)
    }

    @Test func `a swap with nothing in flight takes effect at once`() async throws {
        let container = try makeTestContainer()
        let backend = StubSyncBackend(mirrorContainer: container)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: backend)

        await coordinator.replaceEngine(mirrorContainer: container, namespace: .icloud, defaults: LumeCloudBackendFixture.makeDefaults())

        #expect(coordinator.engineNamespace == .icloud)
        #expect(backend.calls.isEmpty)
    }

    @Test func `a swap waits for the in-flight pass and runs queued passes on the new engine`() async throws {
        let container = try makeTestContainer()
        let mirror = try makeTestContainer()
        let stub = StubSyncBackend(mirrorContainer: container)
        let swapping = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: stub)

        stub.holdPull = true
        swapping.reconcile(reason: .queued, debounced: false)
        await waitUntil { stub.calls == ["pull"] }
        #expect(stub.calls == ["pull"])

        let swap = Task {
            await swapping.replaceEngine(mirrorContainer: mirror, namespace: .icloud, defaults: LumeCloudBackendFixture.makeDefaults())
            stub.record("swapped")
        }
        try? await Task.sleep(for: .milliseconds(100))
        // Requested mid-swap: must not start on either engine yet.
        swapping.reconcile(reason: .queued, debounced: false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.calls == ["pull"])
        #expect(swapping.engineNamespace == .lumecloud)

        stub.holdPull = false
        await swap.value
        #expect(swapping.engineNamespace == .icloud)

        await waitUntil { stub.calls.count >= 5 }
        #expect(stub.calls == ["pull", "push", "swapped", "pull", "push"])
    }

    @Test func `concurrent swaps settle on the last one without overlapping passes`() async throws {
        let container = try makeTestContainer()
        let stub = StubSyncBackend(mirrorContainer: container)
        let coordinator = CloudSyncCoordinator(catalogContainer: container, cloudContainer: container, backend: stub)

        stub.holdPull = true
        coordinator.reconcile(reason: .queued, debounced: false)
        await waitUntil { stub.calls == ["pull"] }

        let first = Task { await coordinator.replaceEngine(mirrorContainer: container, namespace: .icloud, defaults: LumeCloudBackendFixture.makeDefaults()) }
        try? await Task.sleep(for: .milliseconds(50))
        let second = Task { await coordinator.replaceEngine(mirrorContainer: container, namespace: .lumecloud, defaults: LumeCloudBackendFixture.makeDefaults()) }
        try? await Task.sleep(for: .milliseconds(50))

        stub.holdPull = false
        await first.value
        await second.value

        #expect(coordinator.engineNamespace == .lumecloud)
        #expect(stub.calls == ["pull", "push"])
    }
}
