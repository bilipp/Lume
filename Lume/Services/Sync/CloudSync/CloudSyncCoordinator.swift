import CloudKit
import CoreData
import Foundation
import SwiftData
import SwiftUI

/// Drives iCloud sync: owns the reconcile engine, tracks account/sync status for
/// the UI, and decides *when* to reconcile.
///
/// Reconcile triggers are chosen to never collide with active playback (a
/// SwiftData save during playback hitches the player — see the project's player
/// notes): launch, foreground / background transitions, after a content sync
/// finishes (so a freshly fetched catalog picks up its pending cloud state), and
/// when CloudKit reports it merged remote changes. There is deliberately no
/// per-save trigger.
///
/// Injected into the environment so settings can show status. Created once in
/// `LumeApp`.
@MainActor
@Observable
final class CloudSyncCoordinator {
    let status = CloudSyncStatus()

    private let engine: CloudSyncEngine
    private let cloudKitContainerIdentifier: String
    /// False under previews / automated tests, where touching CloudKit
    /// (`CKContainer`, mirroring) crashes an un-entitled binary. Account checks
    /// are skipped; the engine still reconciles the local user-data store.
    private let cloudKitEnabled: Bool

    /// Coalescing guard: a reconcile requested while one is running sets
    /// `pendingReconcile` instead of overlapping, then runs once afterwards.
    private var isReconciling = false
    private var pendingReconcile = false

    private var observers: [NSObjectProtocol] = []

    init(container: ModelContainer, cloudKitContainerIdentifier: String, cloudKitEnabled: Bool) {
        engine = CloudSyncEngine(container: container)
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.cloudKitEnabled = cloudKitEnabled
        guard cloudKitEnabled else { return }
        observeCloudKitEvents()
        observeRemoteChanges()
        observeContentSyncCompletion()
    }

    // No `deinit`: this coordinator is created once in `LumeApp` and lives for
    // the whole process, so its notification observers never need tearing down
    // (and a `@MainActor` `deinit` can't touch the isolated `observers` anyway).

    // MARK: - Lifecycle entry points

    /// Called once at launch: determine account reachability, then run a first
    /// reconcile.
    func start() async {
        await refreshAccountStatus()
        reconcile()
    }

    /// Foreground re-checks account + pulls; background flushes local changes.
    func handleScenePhaseChange(to phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await refreshAccountStatus() }
            reconcile()
        case .background, .inactive:
            reconcile()
        @unknown default:
            break
        }
    }

    // MARK: - Reconcile

    /// Request a reconcile. Coalesces concurrent requests into at most one
    /// in-flight pass plus one queued follow-up.
    func reconcile() {
        guard !isReconciling else {
            pendingReconcile = true
            return
        }
        isReconciling = true

        Task {
            let result = await engine.reconcile()
            // Back on the main actor (this closure is main-actor isolated).
            status.lastReconcile = Date()
            status.lastResult = result

            isReconciling = false
            if pendingReconcile {
                pendingReconcile = false
                reconcile()
            }
        }
    }

    // MARK: - Account status

    func refreshAccountStatus() async {
        guard cloudKitEnabled else { return }
        let container = CKContainer(identifier: cloudKitContainerIdentifier)
        do {
            let status = try await container.accountStatus()
            self.status.account = Self.map(status)
        } catch {
            status.account = .couldNotDetermine
        }
    }

    private static func map(_ status: CKAccountStatus) -> CloudAccountStatus {
        switch status {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .couldNotDetermine
        @unknown default: .couldNotDetermine
        }
    }

    // MARK: - CloudKit / store observers

    /// Mirror `NSPersistentCloudKitContainer` import/export events into the
    /// observable status so settings can show "Syncing…" and surface errors.
    private func observeCloudKitEvents() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            else { return }
            // Runs on the main queue; hop to the isolated actor to mutate state.
            let inProgress = event.endDate == nil
            let errorText = event.error?.localizedDescription
            MainActor.assumeIsolated {
                self?.applyCloudKitEvent(inProgress: inProgress, error: errorText)
            }
        }
        observers.append(observer)
    }

    private func applyCloudKitEvent(inProgress: Bool, error: String?) {
        status.isSyncing = inProgress
        if let error {
            status.lastError = error
        } else if !inProgress {
            status.lastError = nil
        }
    }

    /// CloudKit merged remote changes into the local store — pull them through
    /// the reconciler so they reach the catalog models and the UI.
    private func observeRemoteChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile()
            }
        }
        observers.append(observer)
    }

    /// After a playlist's catalog finishes syncing, run a reconcile so any cloud
    /// user state that was waiting for that catalog gets applied.
    private func observeContentSyncCompletion() {
        let observer = NotificationCenter.default.addObserver(
            forName: .lumeContentSyncDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile()
            }
        }
        observers.append(observer)
    }
}

extension Notification.Name {
    /// Posted by `ContentSyncManager` after a playlist's catalog sync succeeds.
    static let lumeContentSyncDidComplete = Notification.Name("LumeContentSyncDidComplete")
}
