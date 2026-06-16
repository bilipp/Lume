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

    /// Trailing-debounce for notification-driven reconciles. A large CloudKit
    /// import posts a remote-change notification per batch; without this each one
    /// would fire its own full reconcile pass. Collapsing a burst into one pass
    /// matters most now that every pass scans the user-data store.
    private var reconcileDebounceTask: Task<Void, Never>?
    private static let reconcileDebounceDelay: Duration = .milliseconds(600)

    /// Set once the launch-time sync is judged settled; the initial-sync gate
    /// (`status.hasCompletedInitialSync`) then opens after the next reconcile
    /// finishes, so any imported cloud playlists are already materialised into
    /// local `Playlist` records before the UI decides what to show.
    private var shouldOpenInitialSyncGate = false

    /// Set while CloudKit is importing remote data, so a foreground return or a
    /// bare `.NSPersistentStoreRemoteChange` knows there is actually something new
    /// to pull. Consumed (reset) when a reconcile pass starts. Export acks and
    /// setup events don't set it, so pushing our own changes no longer
    /// self-triggers an empty pass — and a foreground with nothing imported skips
    /// the catalog scan and the `@Query` refresh that froze the UI on tvOS.
    private var cloudImportPending = false

    private var observers: [NSObjectProtocol] = []

    init(catalogContainer: ModelContainer, cloudContainer: ModelContainer, cloudKitContainerIdentifier: String, cloudKitEnabled: Bool) {
        engine = CloudSyncEngine(catalogContainer: catalogContainer, cloudContainer: cloudContainer)
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
            reconcile(reason: .launch)
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
        reconcile(reason: .launch)
        scheduleInitialSyncTimeout()
    }

    /// Foreground re-checks account + pulls; background flushes local changes.
    func handleScenePhaseChange(to phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await refreshAccountStatus() }
            // Don't scan on a bare foreground. CloudKit's reconnect posts its own
            // import event when remote data actually arrives, and that drives the
            // pull; a foreground with nothing imported has nothing to merge, and
            // that empty pass — plus the `@Query` refresh it triggers over the
            // whole catalog — is what froze the app on tvOS.
            reconcile(reason: .foreground)
        case .background, .inactive:
            // Flush local edits now, not debounced: the system may suspend the app
            // before a delayed pass could run. Always runs — this is how a toggled
            // favorite or watch-progress reaches the cloud, and the safety net that
            // lets foreground / remote-change passes skip freely.
            reconcile(reason: .backgroundFlush, debounced: false)
        @unknown default:
            break
        }
    }

    // MARK: - Reconcile

    /// Request a reconcile. Notification-driven callers debounce (the default) so
    /// a burst collapses into a single pass; callers that must run promptly (a
    /// background flush before suspension) pass `debounced: false`. Either way
    /// concurrent passes coalesce into at most one in-flight pass plus one queued
    /// follow-up.
    func reconcile(reason: ReconcileReason = .queued, debounced: Bool = true) {
        guard shouldRun(reason) else {
            Logger.sync.debug("Reconcile skipped (\(String(describing: reason), privacy: .public)) — no pending CloudKit import")
            return
        }
        guard debounced else {
            reconcileDebounceTask?.cancel()
            reconcileDebounceTask = nil
            runReconcile()
            return
        }
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconcileDebounceDelay)
            guard !Task.isCancelled else { return }
            self?.runReconcile()
        }
    }

    /// A foreground return or a bare store-change notification only merits a pass
    /// when CloudKit has imported remote data since the last one; everything else
    /// always runs. Keeping the pre-suspension flush unconditional is what makes
    /// skipping safe — a local edit still reaches the cloud when the app
    /// backgrounds, even if every foreground / remote-change pass was skipped.
    private func shouldRun(_ reason: ReconcileReason) -> Bool {
        switch reason {
        case .launch, .backgroundFlush, .contentSync, .queued:
            true
        case .foreground, .remoteChange:
            cloudImportPending
        }
    }

    private func runReconcile() {
        guard !isReconciling else {
            pendingReconcile = true
            return
        }
        isReconciling = true
        // This pass pulls whatever CloudKit imported, so consume the flag now; an
        // import that lands mid-pass sets it again and queues a follow-up.
        cloudImportPending = false

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

    // MARK: - Profiles

    /// Bootstrap the profile store (ensure a default, resolve the active profile,
    /// claim legacy records). Falls back to the preferred/default id on failure
    /// so the app still launches into a usable profile.
    func bootstrapProfiles(preferredActiveID: UUID?, defaultName: String) async -> ProfileBootstrap {
        do {
            return try await engine.bootstrapProfiles(preferredActiveID: preferredActiveID, defaultName: defaultName)
        } catch {
            Logger.sync.error("Profile bootstrap failed: \(error.localizedDescription)")
            return ProfileBootstrap(
                activeProfileID: preferredActiveID ?? UserProfile.defaultProfileID,
                profileCount: 1
            )
        }
    }

    /// Re-project the catalog from one profile to another (flush, reset, hydrate).
    func switchProfile(from: UUID, to toID: UUID) async {
        do {
            try await engine.switchProfile(from: from, to: toID)
        } catch {
            Logger.sync.error("Profile switch failed: \(error.localizedDescription)")
        }
    }

    /// Delete a profile's content state.
    func purgeProfileData(_ id: UUID) async {
        do {
            try await engine.purgeProfileData(id)
        } catch {
            Logger.sync.error("Profile purge failed: \(error.localizedDescription)")
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
        reconcile(reason: .launch)
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
        // Pause background indexing while CloudKit imports/exports: it tears
        // down and re-adds stores on the shared coordinator, and a catalog
        // fault during that window throws an uncatchable `no such table`
        // NSException (see ContentIndexer).
        ContentIndexingService.shared.isCloudSyncActive = inProgress
        if let error {
            status.lastError = error
        } else if !inProgress {
            status.lastError = nil
        }
        // An import means remote data is actually landing in the local store — arm
        // the gate so the foreground / remote-change passes know to pull, and run
        // one when the import finishes. Export acks and `.setup` don't arm it, so
        // pushing our own edits no longer self-triggers an empty reconcile.
        if type == .import {
            cloudImportPending = true
            if !inProgress {
                reconcile(reason: .remoteChange)
            }
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
    /// the reconciler so they reach the catalog models and the UI. Gated on an
    /// actual import (`.remoteChange`): this fires for our own export acks too,
    /// and reconciling on those is the redundant pass we want to avoid.
    private func observeRemoteChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile(reason: .remoteChange)
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
                self?.reconcile(reason: .contentSync)
            }
        }
        observers.append(observer)
    }
}

/// Why a reconcile was requested — determines whether a pass with nothing to do
/// can be skipped. A foreground return and a bare `.NSPersistentStoreRemoteChange`
/// only run when CloudKit actually imported remote data (`cloudImportPending`);
/// launch, the pre-suspension flush, a finished catalog sync, and a queued
/// follow-up always run.
enum ReconcileReason {
    /// Cold-launch first pass — establishes the baseline and pulls anything
    /// CloudKit already imported.
    case launch
    /// App returned to the foreground.
    case foreground
    /// App is suspending — flush local edits to the cloud before it does.
    case backgroundFlush
    /// CloudKit reported a store change (import, or our own export ack).
    case remoteChange
    /// A playlist's catalog finished syncing, so pending cloud state can apply.
    case contentSync
    /// An internal follow-up pass (coalesced overlap, or a post-profile-switch
    /// re-baseline) — always runs.
    case queued
}

extension Notification.Name {
    /// Posted by `ContentSyncManager` after a playlist's catalog sync succeeds.
    static let lumeContentSyncDidComplete = Notification.Name("LumeContentSyncDidComplete")
}
