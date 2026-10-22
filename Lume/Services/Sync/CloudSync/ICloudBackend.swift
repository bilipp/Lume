import CloudKit
import CoreData
import Foundation
import OSLog
import SwiftData

/// iCloud: `NSPersistentCloudKitContainer` mirrors `CloudUserData.store` on its
/// own, so `pull` and `push` have nothing to transfer. This backend tracks the
/// account, turns CloudKit's import/export events into status and reconcile
/// requests, and decides when the launch-time sync has settled.
@MainActor
final class ICloudBackend: SyncBackend {
    let kind: SyncBackendKind? = .icloud
    let mirrorContainer: ModelContainer?

    private let cloudKitContainerIdentifier: String
    /// False under previews / automated tests, where touching CloudKit
    /// (`CKContainer`, mirroring) crashes an un-entitled binary. Account checks
    /// are skipped; the engine still reconciles the local user-data store.
    private let cloudKitEnabled: Bool

    private weak var host: (any SyncBackendHost)?

    /// Set while CloudKit is importing remote data, so a foreground return or a
    /// bare `.NSPersistentStoreRemoteChange` knows there is actually something new
    /// to pull. Consumed (reset) when a reconcile pass starts. Export acks and
    /// setup events don't set it, so pushing our own changes no longer
    /// self-triggers an empty pass — and a foreground with nothing imported skips
    /// the catalog scan and the `@Query` refresh that froze the UI on tvOS.
    private(set) var hasPendingChanges = false

    /// Whether this backend paused `ContentIndexingService`, so `stop()` can
    /// release it if CloudKit was mid-event.
    private var pausedIndexing = false

    private var observers: [NSObjectProtocol] = []

    var waitsForInitialSync: Bool {
        cloudKitEnabled
    }

    init(mirrorContainer: ModelContainer, cloudKitContainerIdentifier: String, cloudKitEnabled: Bool) {
        self.mirrorContainer = mirrorContainer
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.cloudKitEnabled = cloudKitEnabled
        guard cloudKitEnabled else { return }
        observeCloudKitEvents()
        observeRemoteChanges()
    }

    // No `deinit`: the backend lives as long as the coordinator, and a
    // `@MainActor` `deinit` can't touch the isolated `observers` anyway.

    func attach(to host: any SyncBackendHost) {
        self.host = host
    }

    func start() async {
        await refreshStatus()
        guard cloudKitEnabled else {
            // Gate already open; just reconcile the local store.
            host?.reconcile(reason: .launch, debounced: true)
            return
        }
        guard host?.status.account.canSync == true else {
            // No usable iCloud account: nothing will arrive, so don't strand the
            // user on the launch spinner — reconcile and open the gate so the
            // add-playlist form shows as a fallback.
            host?.backendDidSettleInitialSync()
            return
        }
        // Account is usable: pull anything CloudKit already imported, and arm a
        // safety-net timeout so an offline launch (or a brand-new empty account
        // that never reports an import) can't spin forever.
        host?.reconcile(reason: .launch, debounced: true)
        scheduleInitialSyncTimeout()
    }

    func refreshStatus() async {
        guard cloudKitEnabled else { return }
        let container = CKContainer(identifier: cloudKitContainerIdentifier)
        let account: CloudAccountStatus
        do {
            account = try await Self.map(container.accountStatus())
        } catch {
            account = .couldNotDetermine
        }
        host?.status.account = account
    }

    /// CloudKit already imported into the mirror; the pass only has to consume
    /// the flag. An import that lands mid-pass sets it again and queues a
    /// follow-up.
    func pull() async throws {
        hasPendingChanges = false
    }

    /// CloudKit exports the mirror on its own.
    func push() async throws {}

    func stop() {
        host = nil
        hasPendingChanges = false
        if pausedIndexing {
            pausedIndexing = false
            ContentIndexingService.shared.isCloudSyncActive = false
        }
    }

    /// Safety net: settle after a bounded wait so a brand-new but empty account,
    /// or an offline launch where CloudKit never reports an import, can't leave
    /// the user staring at the launch spinner forever.
    private func scheduleInitialSyncTimeout() {
        Task { [weak self] in
            try? await Task.sleep(for: CloudSyncCoordinator.initialSyncTimeout)
            self?.host?.backendDidSettleInitialSync()
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

    /// The `CloudUserData` container stays open while another backend is
    /// active (it carries `SyncedBackendChoice`), so its events keep arriving;
    /// only an attached backend acts on them.
    private func applyCloudKitEvent(
        type: NSPersistentCloudKitContainer.EventType,
        inProgress: Bool,
        error: String?
    ) {
        guard let host else { return }
        let status = host.status
        status.isSyncing = inProgress
        // Pause background indexing while CloudKit imports/exports: it tears
        // down and re-adds stores on the shared coordinator, and a catalog
        // fault during that window throws an uncatchable `no such table`
        // NSException (see ContentIndexer).
        ContentIndexingService.shared.isCloudSyncActive = inProgress
        pausedIndexing = inProgress
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
            hasPendingChanges = true
            if !inProgress {
                host.reconcile(reason: .remoteChange, debounced: true)
            }
        }
        // The launch-time fetch from iCloud has settled once the first import
        // completes (the data has landed) or any event errors (so we fall back
        // rather than spin). A finished `.setup` is too early — the import that
        // carries the playlists hasn't run yet.
        if (type == .import && !inProgress) || error != nil {
            host.backendDidSettleInitialSync()
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
                self?.host?.reconcile(reason: .remoteChange, debounced: true)
            }
        }
        observers.append(observer)
    }
}
