import CloudKit
import CoreData
import Foundation
import OSLog
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

    /// Set once the launch-time sync is judged settled; the initial-sync gate
    /// (`status.hasCompletedInitialSync`) then opens after the next reconcile
    /// finishes, so any imported cloud playlists are already materialised into
    /// local `Playlist` records before the UI decides what to show.
    private var shouldOpenInitialSyncGate = false

    private var observers: [NSObjectProtocol] = []

    init(container: ModelContainer, cloudKitContainerIdentifier: String, cloudKitEnabled: Bool) {
        engine = CloudSyncEngine(container: container)
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.cloudKitEnabled = cloudKitEnabled
        // Nothing to sync under previews / tests: open the launch gate now so an
        // empty store shows the add-playlist form immediately, as before.
        status.hasCompletedInitialSync = !cloudKitEnabled
        guard cloudKitEnabled else { return }
        observeCloudKitEvents()
        observeRemoteChanges()
        observeContentSyncCompletion()
    }

    // No `deinit`: this coordinator is created once in `LumeApp` and lives for
    // the whole process, so its notification observers never need tearing down
    // (and a `@MainActor` `deinit` can't touch the isolated `observers` anyway).

    // MARK: - Lifecycle entry points

    /// Called once at launch: determine account reachability, run a first
    /// reconcile, and arm the initial-sync gate that a fresh install waits on
    /// before showing the add-playlist form.
    func start() async {
        await refreshAccountStatus()
        guard cloudKitEnabled else {
            // Gate already open from `init`; just reconcile the local store.
            reconcile()
            return
        }
        guard status.account.canSync else {
            // No usable iCloud account: nothing will arrive, so don't strand the
            // user on the launch spinner — reconcile and open the gate so the
            // add-playlist form shows as a fallback.
            completeInitialSync()
            return
        }
        // Account is usable: pull anything CloudKit already imported, and arm a
        // safety-net timeout so an offline launch (or a brand-new empty account
        // that never reports an import) can't spin forever.
        reconcile()
        scheduleInitialSyncTimeout()
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
            } else if shouldOpenInitialSyncGate, !status.hasCompletedInitialSync {
                // Open the gate only after the last queued pass, so imported
                // playlists are fully materialised before the form decision.
                status.hasCompletedInitialSync = true
            }
        }
    }

    // MARK: - Initial-sync gate

    /// Judge the launch-time iCloud sync settled and open the gate that a fresh
    /// install waits on. Triggers a reconcile first (so cloud playlists already
    /// imported become local `Playlist` records), then opens the gate when it
    /// finishes — letting `ContentView` show the main app if playlists arrived,
    /// or fall back to the add-playlist form if not. Idempotent: only the first
    /// call has any effect.
    private func completeInitialSync() {
        guard cloudKitEnabled, !status.hasCompletedInitialSync, !shouldOpenInitialSyncGate else { return }
        shouldOpenInitialSyncGate = true
        reconcile()
    }

    /// Safety net: open the gate after a bounded wait so a brand-new but empty
    /// account, or an offline launch where CloudKit never reports an import,
    /// can't leave the user staring at the launch spinner forever.
    private func scheduleInitialSyncTimeout() {
        Task {
            try? await Task.sleep(for: .seconds(15))
            completeInitialSync()
        }
    }

    /// The user tapped "Continue Without Syncing" on the launch screen: stop
    /// waiting and fall through to the add-playlist form. Sync keeps running in
    /// the background, so cloud playlists still appear if they arrive later.
    func skipInitialSyncWait() {
        status.hasCompletedInitialSync = true
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
            let type = event.type
            let inProgress = event.endDate == nil
            let errorText = Self.describe(event.error, eventType: type)
            MainActor.assumeIsolated {
                self?.applyCloudKitEvent(type: type, inProgress: inProgress, error: errorText)
            }
        }
        observers.append(observer)
    }

    private func applyCloudKitEvent(
        type: NSPersistentCloudKitContainer.EventType,
        inProgress: Bool,
        error: String?
    ) {
        status.isSyncing = inProgress
        if let error {
            status.lastError = error
        } else if !inProgress {
            status.lastError = nil
        }
        // The launch-time fetch from iCloud has settled once the first import
        // completes (the data has landed) or any event errors (so we fall back
        // rather than spin). A finished `.setup` is too early — the import that
        // carries the playlists hasn't run yet.
        if (type == .import && !inProgress) || error != nil {
            completeInitialSync()
        }
    }

    /// Turn a CloudKit sync-event error into a readable message, logging the full
    /// detail to `Logger.sync`.
    ///
    /// A CloudKit `partialFailure` — the opaque "CKErrorDomain error 2" that
    /// reaches the user — hides the real cause inside `partialErrorsByItemID`;
    /// `localizedDescription` on its own just repeats "error 2". Unwrapping the
    /// per-record errors lets the log (and the settings screen) name what
    /// actually failed — most often a record type that isn't in the deployed
    /// CloudKit schema yet (e.g. a build pointed at an environment whose schema
    /// was never deployed: every record is rejected and the batch reports
    /// `partialFailure`).
    private nonisolated static func describe(
        _ error: Error?,
        eventType: NSPersistentCloudKitContainer.EventType
    ) -> String? {
        guard let error else { return nil }
        let phase = eventName(eventType)

        // Usually the CKError directly; occasionally a Cocoa error wrapping it.
        let ckError = (error as? CKError)
            ?? ((error as NSError).userInfo[NSUnderlyingErrorKey] as? Error)
            .flatMap { $0 as? CKError }

        if let ckError, ckError.code == .partialFailure,
           let perItem = ckError.partialErrorsByItemID, !perItem.isEmpty
        {
            for (itemID, itemError) in perItem {
                Logger.sync.error(
                    "CloudKit \(phase, privacy: .public) rejected \(String(describing: itemID), privacy: .public): \(String(reflecting: itemError), privacy: .public)"
                )
            }
            // Records usually all fail identically; collapse to the distinct
            // underlying messages so the UI shows the cause, not "error 2".
            let messages = Set(perItem.values.map { ($0 as NSError).localizedDescription })
            return messages.sorted().joined(separator: "; ")
        }

        Logger.sync.error("CloudKit \(phase, privacy: .public) failed: \(String(reflecting: error), privacy: .public)")
        return error.localizedDescription
    }

    private nonisolated static func eventName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "unknown"
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
