//
//  LumeCloudEventListenerTests.swift
//  LumeTests
//
//  The Lume Cloud socket: `LumeCloudEventListener`'s reconnect backoff and
//  refused-upgrade probe over scripted sockets, then `LumeCloudBackend`'s live
//  updates against `StubLumeCloudAccountServer` — a poke pulls only past the
//  cursor, an echo costs no pass, and a refused socket routes a revoked device
//  or a deleted account like a failed pass. No network.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Synchronization
import Testing

/// Hands out one scripted socket per connection.
@MainActor
private final class ScriptedSockets {
    enum Script {
        /// Yields these seqs, then ends normally or with the error.
        case session([Int], then: LumeCloudError?)
        /// Stays open until the listener closes it.
        case open
    }

    var scripts: [Script]
    private(set) var connections = 0
    private(set) var closedOpenSockets = 0

    init(_ scripts: [Script]) {
        self.scripts = scripts
    }

    func connect() -> AsyncThrowingStream<Int, Error> {
        connections += 1
        let script = scripts.isEmpty ? .open : scripts.removeFirst()
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        switch script {
        case let .session(seqs, error):
            for seq in seqs {
                continuation.yield(seq)
            }
            continuation.finish(throwing: error)
        case .open:
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.closedOpenSockets += 1 }
            }
        }
        return stream
    }
}

private final nonisolated class SleepRecorder: Sendable {
    let durations = Mutex<[Duration]>([])

    var recorded: [Duration] {
        durations.withLock { $0 }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
struct LumeCloudEventListenerTests {
    private let backoff = LumeCloudEventListener.Backoff(initial: .milliseconds(1), maximum: .milliseconds(4))
    private let dropped = LumeCloudError.transport(URLError(.networkConnectionLost))

    private func makeListener(
        _ sockets: ScriptedSockets,
        sleeps: SleepRecorder,
        seqs: @escaping (Int) -> Void = { _ in },
        probe: @escaping () async -> LumeCloudEventListener.ProbeVerdict = { .reconnect }
    ) -> LumeCloudEventListener {
        LumeCloudEventListener(
            backoff: backoff,
            sleep: { duration in sleeps.durations.withLock { $0.append(duration) } },
            connect: { sockets.connect() },
            onSeq: { seqs($0) },
            probe: probe
        )
    }

    @Test func `the backoff doubles up to its cap`() {
        let backoff = LumeCloudEventListener.Backoff.standard
        let delays = (1 ... 8).map { backoff.delay(afterFailures: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
        #expect(backoff.delay(afterFailures: 500) == .seconds(60))
    }

    @Test func `a dropped socket reconnects with a growing backoff`() async {
        let sockets = ScriptedSockets([.session([], then: dropped), .session([], then: nil), .open])
        let sleeps = SleepRecorder()
        let listener = makeListener(sockets, sleeps: sleeps)

        listener.start()
        await waitUntil { sockets.connections == 3 }
        listener.stop()

        #expect(sockets.connections == 3)
        #expect(sleeps.recorded == [.milliseconds(1), .milliseconds(2)])
    }

    @Test func `a poke resets the backoff`() async {
        let sockets = ScriptedSockets([.session([5], then: dropped), .session([6], then: dropped), .open])
        let sleeps = SleepRecorder()
        var received: [Int] = []
        let listener = makeListener(sockets, sleeps: sleeps, seqs: { received.append($0) })

        listener.start()
        await waitUntil { sockets.connections == 3 }
        listener.stop()

        #expect(received == [5, 6])
        #expect(sleeps.recorded == [.milliseconds(1), .milliseconds(1)])
    }

    @Test func `stop closes the socket and never reconnects`() async throws {
        let sockets = ScriptedSockets([.open])
        let listener = makeListener(sockets, sleeps: SleepRecorder())

        listener.start()
        await waitUntil { sockets.connections == 1 }
        listener.stop()
        await waitUntil { sockets.closedOpenSockets == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(!listener.isRunning)
        #expect(sockets.connections == 1)
        #expect(sockets.closedOpenSockets == 1)
    }

    @Test func `a refused upgrade probes, and the probe decides whether to reconnect`() async {
        let sockets = ScriptedSockets([.session([], then: .badAuth), .session([], then: dropped), .session([], then: .notFound)])
        var probes = 0
        let listener = makeListener(sockets, sleeps: SleepRecorder(), probe: {
            probes += 1
            return probes == 1 ? .reconnect : .stop
        })

        listener.start()
        await waitUntil { !listener.isRunning }

        #expect(!listener.isRunning)
        #expect(sockets.connections == 3)
        // The plain drop in between never probes.
        #expect(probes == 2)
    }
}

/// Serialized: every test shares one keychain item.
@MainActor
@Suite(.serialized)
struct LumeCloudBackendEventTests {
    private let fixture = LumeCloudBackendFixture(keychainService: "lume.cloud.tests.backend-events")

    private var server: StubLumeCloudAccountServer {
        fixture.server
    }

    private func calls(_ name: String) -> Int {
        server.calls.count { $0 == name }
    }

    private func listeningBackend(defaults: UserDefaults = LumeCloudBackendFixture.makeDefaults()) async throws
        -> (LumeCloudBackend, StubSyncBackendHost)
    {
        let (backend, _) = try await fixture.makeJoinedBackend(defaults: defaults)
        let host = StubSyncBackendHost()
        backend.attach(to: host)
        backend.setListensForEvents(true)
        await waitUntil { server.feed.socketCount == 1 }
        #expect(server.feed.socketCount == 1)
        return (backend, host)
    }

    private func storeRemoteProfile(named name: String, for backend: LumeCloudBackend) throws {
        let keys = try LumeCloudKeys(rootKey: #require(backend.identity).rootKey)
        let profile = UserProfile(name: name, createdAt: .now, updatedAt: .now)
        let (rid, ciphertext) = try keys.seal(LumeCloudPayloadCodec.payload(for: profile, previous: nil))
        server.feed.store(rid: rid, ciphertext: ciphertext)
    }

    @Test func `a poke past the cursor pulls and requests a pass`() async throws {
        let (backend, host) = try await listeningBackend()
        try storeRemoteProfile(named: "Lantern", for: backend)

        server.feed.poke()
        await waitUntil { host.reconciles.contains(.remoteChange) }

        #expect(host.reconciles == [.remoteChange])
        let names = try ModelContext(backend.container).fetch(FetchDescriptor<UserProfile>()).map(\.name)
        #expect(names == ["Lantern"])
        #expect(backend.hasPendingChanges)
        try await backend.pull()
        #expect(!backend.hasPendingChanges)
    }

    @Test func `a poke the cursor already covers sends nothing`() async throws {
        let (backend, host) = try await listeningBackend()
        try storeRemoteProfile(named: "Lantern", for: backend)
        try await backend.pull()
        let pullsBefore = calls("allChanges")

        server.feed.poke()
        try await Task.sleep(for: .milliseconds(100))

        #expect(calls("allChanges") == pullsBefore)
        #expect(host.reconciles.isEmpty)
    }

    @Test func `the echo of an own push pulls but requests no pass`() async throws {
        let (backend, host) = try await listeningBackend()
        let context = ModelContext(backend.container)
        context.insert(UserProfile(name: "Orchard"))
        try context.save()
        try await backend.push()
        let pullsBefore = calls("allChanges")

        server.feed.poke()
        await waitUntil { calls("allChanges") > pullsBefore }
        try await Task.sleep(for: .milliseconds(50))

        #expect(calls("allChanges") == pullsBefore + 1)
        #expect(host.reconciles.isEmpty)
    }

    @Test func `a dropped socket reconnects`() async throws {
        let (backend, _) = try await listeningBackend()

        server.feed.dropSocket(throwing: .transport(URLError(.networkConnectionLost)))
        await waitUntil { server.feed.socketCount == 2 }

        #expect(server.feed.socketCount == 2)
        #expect(backend.eventListener?.isRunning == true)
        #expect(calls("changes") == 0)
    }

    @Test func `a refused socket of a revoked device probes and leaves`() async throws {
        let defaults = LumeCloudBackendFixture.makeDefaults()
        let (backend, host) = try await listeningBackend(defaults: defaults)
        let identity = try #require(backend.identity)
        let deviceID = LumeCloudSettings(defaults: defaults).deviceID
        var ended: [LumeCloudAccountEnd] = []
        backend.onAccountEnded = { ended.append($0) }
        server.state.withLock { $0.devices[identity.accountId]?[deviceID]?.revoked = true }

        server.feed.dropSocket()
        await waitUntil { !ended.isEmpty }

        #expect(ended == [.deviceRevoked])
        #expect(calls("changes") == 1)
        #expect(host.status.lumeCloud == .revoked)
        #expect(backend.eventListener == nil)
        #expect(fixture.keyStore.load() == .identity(identity))
    }

    @Test func `a refused socket of a deleted account probes and clears the keychain`() async throws {
        let (backend, host) = try await listeningBackend()
        let identity = try #require(backend.identity)
        var ended: [LumeCloudAccountEnd] = []
        backend.onAccountEnded = { ended.append($0) }
        server.state.withLock { _ = $0.deletedAccounts.insert(identity.accountId) }

        server.feed.dropSocket()
        await waitUntil { !ended.isEmpty }

        #expect(ended == [.accountDeleted])
        #expect(calls("changes") == 1)
        #expect(host.status.lumeCloud == .accountDeleted)
        #expect(backend.eventListener == nil)
        #expect(fixture.keyStore.load() == .notSet)
    }

    @Test func `the socket runs only while listening, attached and joined`() async throws {
        let (backend, _) = try await fixture.makeJoinedBackend()
        backend.setListensForEvents(true)
        #expect(backend.eventListener == nil)

        let host = StubSyncBackendHost()
        backend.attach(to: host)
        #expect(backend.eventListener?.isRunning == true)

        backend.setListensForEvents(false)
        #expect(backend.eventListener == nil)

        backend.setListensForEvents(true)
        #expect(backend.eventListener?.isRunning == true)
        backend.stop()
        #expect(backend.eventListener == nil)
    }

    @Test func `an inert backend never opens the socket`() throws {
        let backend = try fixture.makeBackend(isInert: true)
        backend.attach(to: StubSyncBackendHost())
        backend.setListensForEvents(true)

        #expect(backend.eventListener == nil)
        #expect(server.feed.socketCount == 0)
    }
}
