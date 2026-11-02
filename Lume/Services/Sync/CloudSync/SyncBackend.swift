import Foundation
import SwiftData

/// The sync backends a device can reconcile against. Each keeps its own
/// `CloudSyncShadow` namespace.
nonisolated enum SyncBackendKind: String {
    case icloud
    case lumecloud
}

nonisolated extension SyncBackendSelection {
    /// `nil` is a backend with no shadow namespace: Off.
    init(_ kind: SyncBackendKind?) {
        switch kind {
        case .icloud: self = .icloud
        case .lumecloud: self = .lumecloud
        case nil: self = .off
        }
    }
}

/// The transport behind `CloudSyncCoordinator`: it moves the mirror store to and
/// from one remote service. The coordinator owns *when* a pass runs; a backend
/// owns *what* "remote" means. Every pass is `pull` → `CloudSyncEngine.reconcile`
/// → `push`, serialized by the coordinator.
@MainActor
protocol SyncBackend: AnyObject {
    /// The shadow namespace this backend reconciles against. `nil` means the
    /// device syncs nowhere (Off), and the coordinator never reconciles.
    var kind: SyncBackendKind? { get }

    /// The mirror store the engine reconciles the catalog against. `nil` for Off.
    var mirrorContainer: ModelContainer? { get }

    /// Whether a fresh install's launch gate should wait for this backend's
    /// first sync. False when there is nothing to wait for (previews, tests, Off).
    var waitsForInitialSync: Bool { get }

    /// Remote data has landed in the mirror since the last pass, so a foreground
    /// return or a bare remote-change notification has something to reconcile.
    /// Consumed by `pull()`.
    var hasPendingChanges: Bool { get }

    /// Connect to the coordinator. Called once, before `start()`, so events the
    /// remote service posts during launch already reach the coordinator.
    func attach(to host: any SyncBackendHost)

    /// Launch: check reachability and request the first pass.
    func start() async

    /// Re-check reachability (foreground return).
    func refreshStatus() async

    /// Bring remote changes into the mirror. Runs at the start of every pass.
    /// A backend that writes remote rows itself posts `.lumeSyncMirrorDidChange`.
    func pull() async throws

    /// Send the mirror's local changes to the remote. Runs at the end of every pass.
    func push() async throws

    /// Detach from the coordinator. A stopped backend ignores its remote
    /// service's events and leaves the shared status alone.
    func stop()

    /// Runs before each pass's pull. True when the mirror was lost since it
    /// last synced: the coordinator then drops its reconcile baseline, or the
    /// empty mirror reads as a deletion of every local item.
    func recoverLostMirror() async -> Bool

    /// Whether to hold a live connection for remote change events. Follows the
    /// scene: open while active, closed otherwise.
    func setListensForEvents(_ listens: Bool)

    /// Called with the server's reason when it ends this device's membership.
    func observeAccountEnd(_ handler: @escaping (LumeCloudAccountEnd) -> Void)

    /// Runs on a switch into this backend, before the previous mirror's data
    /// is copied into `mirrorContainer`.
    func prepareMirrorForAttach() async throws

    /// The user deleted a playlist; the engine already removed its rows.
    func recordPlaylistDeletion(id: UUID) async

    /// The user deleted a profile; its row is already gone from the mirror.
    func recordProfileDeletion(id: UUID) async

    /// Mirror rows a writer deleted on purpose (`SyncMirrorDeletionLog`),
    /// drained at each pass. A backend whose remote follows the mirror's own
    /// row deletions ignores them.
    func recordRemovals(logicalKeys: [String]) async
}

/// No-ops for a backend whose remote follows the mirror on its own.
extension SyncBackend {
    func recoverLostMirror() async -> Bool {
        false
    }

    func setListensForEvents(_: Bool) {}
    func observeAccountEnd(_: @escaping (LumeCloudAccountEnd) -> Void) {}
    func prepareMirrorForAttach() async throws {}
    func recordPlaylistDeletion(id _: UUID) async {}
    func recordProfileDeletion(id _: UUID) async {}
    func recordRemovals(logicalKeys _: [String]) async {}
}

/// What a `SyncBackend` reports back to. Implemented by `CloudSyncCoordinator`.
@MainActor
protocol SyncBackendHost: AnyObject {
    var status: CloudSyncStatus { get }

    /// Request a pass; the host debounces and coalesces.
    func reconcile(reason: ReconcileReason, debounced: Bool)

    /// The backend's launch-time sync has settled (data landed, the remote is
    /// unusable, or the wait timed out). The host opens the launch gate after
    /// the next pass finishes.
    func backendDidSettleInitialSync()
}
