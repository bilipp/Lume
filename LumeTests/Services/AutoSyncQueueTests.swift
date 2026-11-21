import Foundation
@testable import Lume
import SwiftData
import Testing

/// Stands in for `AutoSync.runSync`: each sync parks until the test ends it.
@MainActor
private final class SyncRunnerStub {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "The server went away."
        }
    }

    private(set) var started: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func run(_ playlist: Playlist) async throws {
        let id = playlist.id
        started.append(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.end(id, throwing: CancellationError()) }
        }
    }

    func isRunning(_ id: UUID) -> Bool {
        waiters[id] != nil
    }

    func end(_ id: UUID, throwing error: Error? = nil) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }
}

@MainActor
struct AutoSyncQueueTests {
    private let container: ModelContainer
    private let stub = SyncRunnerStub()
    private let queue: AutoSyncQueue

    init() throws {
        container = try makeTestContainer()
        let stub = stub
        queue = AutoSyncQueue { playlist, _, _, _ in try await stub.run(playlist) }
    }

    private var context: ModelContext {
        container.mainContext
    }

    private func makePlaylist(_ name: String, synced: Bool = false) -> Playlist {
        let playlist = Playlist(name: name, serverURL: "http://\(name).example.com", username: "u", password: "p")
        if synced { playlist.lastSyncDate = Date().addingTimeInterval(-30 * 24 * 60 * 60) }
        context.insert(playlist)
        return playlist
    }

    /// The queue hops through its own task between states.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0 ..< 2000 where !condition() {
            await Task.yield()
        }
    }

    private func finish(_ playlist: Playlist, throwing error: Error? = nil) async {
        await settle { stub.isRunning(playlist.id) }
        stub.end(playlist.id, throwing: error)
        await settle { queue.running?.job.id != playlist.id }
    }

    @Test func `syncs run one at a time in the order they were asked for`() async {
        let first = makePlaylist("a")
        let second = makePlaylist("b")

        queue.sync(first, context: context)
        queue.sync(second, context: context)

        #expect(queue.running?.job.id == first.id)
        #expect(queue.upNext.map(\.id) == [second.id])
        #expect(queue.isBusy)

        await finish(first)
        #expect(queue.running?.job.id == second.id)
        #expect(queue.upNext.isEmpty)

        await finish(second)
        #expect(queue.running == nil)
        #expect(!queue.isBusy)
        #expect(stub.started == [first.id, second.id])
    }

    @Test func `a manual sync goes ahead of the automatic ones waiting`() {
        let running = makePlaylist("a")
        let automatic = makePlaylist("b")
        let manual = makePlaylist("c")
        let scope = CatalogScope.isolated(automatic.id)

        queue.sync(running, context: context)
        queue.enqueueDue([automatic], scope: scope, frequency: .daily, context: context)
        queue.sync(manual, context: context)

        #expect(queue.upNext.map(\.id) == [manual.id, automatic.id])
        #expect(queue.upNext.map(\.isManual) == [true, false])
    }

    @Test func `asking twice for the same playlist queues it once`() {
        let playlist = makePlaylist("a")
        let other = makePlaylist("b")

        queue.sync(playlist, context: context)
        queue.sync(playlist, context: context)
        queue.sync(other, context: context)
        queue.sync(other, context: context)

        #expect(queue.running?.job.id == playlist.id)
        #expect(queue.upNext.map(\.id) == [other.id])
    }

    @Test func `a finished sync is kept until the viewer has seen it`() async {
        let playlist = makePlaylist("a")
        queue.sync(playlist, context: context)
        await finish(playlist)

        #expect(queue.recent?.job.id == playlist.id)
        #expect(queue.recent?.failed == false)
        #expect(queue.recentFailure() == nil)

        queue.acknowledgeRecent()
        #expect(queue.recent == nil)
    }

    @Test func `a failure is reported for its own playlist and can be retried`() async {
        let playlist = makePlaylist("a")
        let other = makePlaylist("b")
        queue.sync(playlist, context: context)
        await finish(playlist, throwing: SyncRunnerStub.Failure())

        #expect(queue.running == nil)
        #expect(queue.recentFailure()?.errorMessage == "The server went away.")
        #expect(queue.recentFailure(in: [playlist.id]) != nil)
        #expect(queue.recentFailure(in: [other.id]) == nil)

        queue.retryRecent(context: context)
        #expect(queue.running?.job.id == playlist.id)
        #expect(queue.recentFailure() == nil)

        await finish(playlist)
        #expect(stub.started == [playlist.id, playlist.id])
        #expect(queue.recent?.failed == false)
    }

    @Test func `stopping a sync leaves no result and moves on`() async {
        let stopped = makePlaylist("a")
        let next = makePlaylist("b")
        queue.sync(stopped, context: context)
        queue.sync(next, context: context)
        await settle { stub.isRunning(stopped.id) }

        queue.stopRunning()
        await settle { queue.running?.job.id == next.id }

        #expect(queue.running?.job.id == next.id)
        #expect(queue.recent == nil)
    }

    @Test func `a deleted playlist takes its syncs with it`() async {
        let kept = makePlaylist("a")
        let deletedWhileRunning = makePlaylist("b")
        let deletedWhileWaiting = makePlaylist("c")
        queue.sync(deletedWhileRunning, context: context)
        queue.sync(deletedWhileWaiting, context: context)
        queue.sync(kept, context: context)
        await settle { stub.isRunning(deletedWhileRunning.id) }

        queue.dropSyncs(notIn: [kept.id])
        await settle { queue.running?.job.id == kept.id }

        #expect(queue.running?.job.id == kept.id)
        #expect(queue.upNext.isEmpty)
        #expect(!stub.started.contains(deletedWhileWaiting.id))
    }

    @Test func `syncing is reported for the playlists it concerns`() {
        let running = makePlaylist("a")
        let waiting = makePlaylist("b")
        let idle = makePlaylist("c")
        queue.sync(running, context: context)
        queue.sync(waiting, context: context)

        #expect(queue.isSyncing(anyOf: [running.id]))
        #expect(queue.isSyncing(anyOf: [waiting.id]))
        #expect(!queue.isSyncing(anyOf: [idle.id]))
    }

    @Test func `a tab waits for its step only during a first import`() {
        let fresh = makePlaylist("a")
        queue.sync(fresh, context: context)
        let scope = CatalogScope.isolated(fresh.id)

        #expect(queue.isFirstImportAwaiting(.movies, in: scope))
        // Not a step of an Xtream sync: nothing to wait for.
        #expect(!queue.isFirstImportAwaiting(.playlistImport, in: scope))
        #expect(!queue.isFirstImportAwaiting(.movies, in: .isolated(UUID())))

        queue.running?.progress.start(.movies)
        queue.running?.progress.complete(.movies)
        #expect(!queue.isFirstImportAwaiting(.movies, in: scope))
        #expect(queue.isFirstImportAwaiting(.series, in: scope))
    }

    @Test func `a refresh never hides the rows already there`() {
        let synced = makePlaylist("a", synced: true)
        queue.sync(synced, context: context)

        #expect(!queue.isFirstImportAwaiting(.movies, in: .isolated(synced.id)))
    }
}
