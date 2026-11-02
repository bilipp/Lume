import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Drives sync: owns the reconcile engine, fronts the active `SyncBackend`, and
/// decides *when* to reconcile.
///
/// Reconcile triggers are chosen to never collide with active playback (a
/// SwiftData save during playback hitches the player — see the project's player
/// notes): launch, foreground / background transitions, after a content sync
/// finishes (so a freshly fetched catalog picks up its pending cloud state), and
/// when the backend reports that remote changes landed. There is deliberately no
/// per-save trigger.
///
/// Injected into the environment so settings can show status. Created once in
/// `LumeApp`.
@MainActor
@Observable
final class CloudSyncCoordinator {
    let status = CloudSyncStatus()

    private let catalogContainer: ModelContainer
    private(set) var engine: CloudSyncEngine
    /// Backs the shadow, the engine and `settings`.
    let defaults: UserDefaults
    /// Mirror rows deleted on purpose, drained into the backend at each pass.
    /// Every engine this coordinator builds reports into it.
    let deletionLog: SyncMirrorDeletionLog
    /// Where the device's backend choice persists.
    let settings: LumeCloudSettings
    /// The mirror store the engine reconciles against and its readers follow.
    /// Off keeps the previous backend's, so profiles stay readable.
    private(set) var mirrorContainer: ModelContainer
    /// The shadow namespace the current engine reconciles against.
    private(set) var engineNamespace: SyncBackendKind
    /// The transport every pass runs through. Its events are scoped to it: the
    /// coordinator only hears from the backend it attached.
    private(set) var backend: any SyncBackend
    /// Every backend this coordinator has run or can switch to, by selection.
    /// No `.icloud` entry means this build can't use iCloud.
    var backends: [SyncBackendSelection: any SyncBackend] = [:]
    let makeLumeCloudBackend: () throws -> LumeCloudBackend
    /// The running backend switch, so switches never interleave.
    var switchTask: Task<Void, Never>?
    /// Told after each completed backend switch, with the previous and the new
    /// selection and why it ran. `SyncedBackendChoiceWatcher` mirrors it to iCloud.
    var onBackendSwitched: ((_ from: SyncBackendSelection, _ to: SyncBackendSelection, _ cause: SyncBackendSwitchCause) -> Void)?
    /// Set once the server ended this device's Lume Cloud membership and the
    /// device tried to switch away; the UI shows the notice and clears it.
    var accountEndNotice: LumeCloudAccountEndNotice?
    /// The Lume Cloud account the user's other Apple devices sync with, for the
    /// first-run sync choice to offer. Set by `SyncedBackendChoiceWatcher`
    /// while the choice is up. Never log it.
    var offeredLumeCloudAccount: LumeCloudIdentity?

    /// Coalescing guard: a reconcile requested while one is running sets
    /// `pendingReconcile` instead of overlapping, then runs once afterwards.
    private var isReconciling = false
    private var pendingReconcile = false
    /// True while a Sync Now from Settings is running (`syncNow()`).
    var isSyncingNow = false
    /// The queued pass is a background flush, so it runs without the debounce.
    private var pendingReconcileIsFlush = false
    /// The in-flight pass, so an engine swap can wait it out.
    private var passTask: Task<Void, Never>?
    /// Engine swaps waiting for the in-flight pass. While non-zero, requested
    /// passes queue instead of starting on the engine about to be replaced.
    private var pendingEngineSwaps = 0
    /// Bumped per `replaceEngine` call; only the latest request is applied.
    private var engineSwapGeneration = 0

    /// Trailing-debounce for notification-driven reconciles. A large CloudKit
    /// import posts a remote-change notification per batch; without this each one
    /// would fire its own full reconcile pass. Collapsing a burst into one pass
    /// matters most now that every pass scans the user-data store.
    private var reconcileDebounceTask: Task<Void, Never>?
    private static let reconcileDebounceDelay: Duration = .milliseconds(600)

    /// How long the launch gate waits on a first sync, from either backend or
    /// an auto-join into Lume Cloud, before opening anyway.
    static let initialSyncTimeout: Duration = .seconds(15)

    /// Set once the launch-time sync is judged settled; the initial-sync gate
    /// (`status.hasCompletedInitialSync`) then opens after the next reconcile
    /// finishes, so any imported cloud playlists are already materialised into
    /// local `Playlist` records before the UI decides what to show.
    private var shouldOpenInitialSyncGate = false
    /// Ends a launch-time Lume Cloud join's hold on the gate when it runs out.
    var launchJoinWaitTask: Task<Void, Never>?

    /// Not `private`: `CloudSyncCoordinator+Episodes.swift` registers one too.
    var observers: [NSObjectProtocol] = []
    private var observesContentSync = false

    /// Readers of the mirror store, repointed when an engine swap changes it.
    private var mirrorConsumers: [WeakMirrorConsumer] = []

    /// Whether the scene is active. Lume Cloud keeps its socket open only then.
    private(set) var isSceneActive = false

    /// Starts on the backend this device last chose (`LumeCloudSettings.backend`),
    /// or Off behind the first-run sync choice when `backendChoice` asks for it.
    convenience init(
        catalogContainer: ModelContainer,
        cloudContainer: ModelContainer,
        cloudKitContainerIdentifier: String,
        cloudKitEnabled: Bool,
        backendChoice: BackendChoiceOffer = .never,
        defaults: UserDefaults = .standard
    ) {
        let iCloud = ICloudBackend(
            mirrorContainer: cloudContainer,
            cloudKitContainerIdentifier: cloudKitContainerIdentifier,
            cloudKitEnabled: cloudKitEnabled
        )
        let settings = LumeCloudSettings(defaults: defaults)
        let awaitsChoice = backendChoice.applies(to: settings, catalogContainer: catalogContainer)
        let launchBackend: any SyncBackend = awaitsChoice ? OffBackend() : Self.launchBackend(
            for: settings.backend,
            iCloud: iCloud,
            makeLumeCloudBackend: { try LumeCloudBackend.makeDefault() }
        )
        self.init(
            catalogContainer: catalogContainer,
            cloudContainer: cloudContainer,
            backend: launchBackend,
            iCloudBackend: iCloud,
            awaitingBackendChoice: awaitsChoice,
            defaults: defaults
        )
    }

    /// `cloudContainer` backs the engine when `backend` has no mirror (Off).
    /// `iCloudBackend` is what a switch to iCloud attaches; nil when this build
    /// can't use iCloud (unless `backend` is the iCloud one).
    /// `awaitingBackendChoice` puts up the first-run sync choice.
    init(
        catalogContainer: ModelContainer,
        cloudContainer: ModelContainer,
        backend: any SyncBackend,
        iCloudBackend: (any SyncBackend)? = nil,
        makeLumeCloudBackend: (() throws -> LumeCloudBackend)? = nil,
        awaitingBackendChoice: Bool = false,
        defaults: UserDefaults = .standard,
        deletionLog: SyncMirrorDeletionLog = .shared
    ) {
        let namespace = backend.kind ?? .icloud
        let mirror = backend.mirrorContainer ?? cloudContainer
        self.catalogContainer = catalogContainer
        self.defaults = defaults
        self.deletionLog = deletionLog
        settings = LumeCloudSettings(defaults: defaults)
        mirrorContainer = mirror
        engine = Self.makeEngine(
            catalogContainer: catalogContainer,
            mirrorContainer: mirror,
            namespace: namespace,
            defaults: defaults,
            deletionLog: deletionLog
        )
        engineNamespace = namespace
        self.backend = backend
        self.makeLumeCloudBackend = makeLumeCloudBackend ?? { try LumeCloudBackend.makeDefault() }
        status.backend = SyncBackendSelection(backend.kind)
        if let iCloudBackend {
            register(iCloudBackend)
        }
        register(backend)
        observers.append(NotificationCenter.default.addObserver(
            forName: .lumeSyncMirrorDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifyMirrorConsumers() }
        })
        observeNewEpisodes()
        // Nothing to wait for under previews / tests / Off: open the launch gate
        // now so an empty store shows the add-playlist form immediately. Behind
        // the first-run choice it stays closed for the chosen backend's first
        // sync (see `finishBackendChoice()`).
        status.isAwaitingBackendChoice = awaitingBackendChoice
        status.hasCompletedInitialSync = !backend.waitsForInitialSync && !awaitingBackendChoice
        backend.attach(to: self)
        guard backend.waitsForInitialSync else { return }
        observeContentSyncCompletion()
    }

    // No `deinit`: this coordinator is created once in `LumeApp` and lives for
    // the whole process, so its notification observers never need tearing down
    // (and a `@MainActor` `deinit` can't touch the isolated `observers` anyway).

    // MARK: - Lifecycle entry points

    /// Called once at launch: the backend checks reachability, requests a first
    /// reconcile, and settles the initial-sync gate that a fresh install waits on
    /// before showing the add-playlist form.
    func start() async {
        isSceneActive = true
        updateEventListening()
        await backend.start()
    }

    /// Foreground re-checks account + pulls; background flushes local changes.
    func handleScenePhaseChange(to phase: ScenePhase) {
        isSceneActive = phase == .active
        updateEventListening()
        switch phase {
        case .active:
            Task { await refreshAccountStatus() }
            // Don't scan on a bare foreground. CloudKit's reconnect posts its own
            // import event when remote data actually arrives, and that drives the
            // pull; a foreground with nothing imported has nothing to merge, and
            // that empty pass — plus the `@Query` refresh it triggers over the
            // whole catalog — is what froze the app on tvOS.
            reconcile(reason: .foreground)
        case .background:
            // Flush local edits now, not debounced: the system may suspend the app
            // before a delayed pass could run. Always runs — this is how a toggled
            // favorite or watch-progress reaches the cloud, and the safety net that
            // lets foreground / remote-change passes skip freely.
            reconcile(reason: .backgroundFlush, debounced: false)
            Task { await holdBackgroundTimeForFlush() }
        case .inactive:
            // iOS, tvOS and visionOS pass through `.inactive` on the way to the
            // background *and* on the way back, and for Control Center, the
            // notification shade and the app switcher. Flushing there ran a full
            // pass on every foreground (defeating the gate above) and a second
            // one queued behind the real background flush. The `.background`
            // that follows a real exit flushes on its own. A Mac app is never
            // suspended and a window going inactive may be the last phase change
            // before quit, so macOS keeps flushing here.
            #if os(macOS)
                reconcile(reason: .backgroundFlush, debounced: false)
            #endif
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
        guard backend.kind != nil else { return }
        if reason == .backgroundFlush, isReconciling || pendingEngineSwaps > 0 {
            pendingReconcileIsFlush = true
        }
        guard shouldRun(reason) else {
            Logger.sync.debug("Reconcile skipped (\(String(describing: reason), privacy: .public)) — no pending remote changes")
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
    /// when the backend has remote data pending since the last one; everything else
    /// always runs. Keeping the pre-suspension flush unconditional is what makes
    /// skipping safe — a local edit still reaches the cloud when the app
    /// backgrounds, even if every foreground / remote-change pass was skipped.
    private func shouldRun(_ reason: ReconcileReason) -> Bool {
        switch reason {
        case .launch, .backgroundFlush, .contentSync, .queued, .manual:
            true
        case .foreground, .remoteChange:
            backend.hasPendingChanges
        }
    }

    private func runReconcile() {
        guard !isReconciling, pendingEngineSwaps == 0 else {
            pendingReconcile = true
            return
        }
        isReconciling = true
        let backend = backend
        let engine = engine
        let deletionLog = deletionLog

        passTask = Task {
            let result = await BackgroundActivity.perform("Sync reconcile") {
                // Before the pull, which may fail: an emptied mirror against the
                // old baseline would delete every local item.
                if await backend.recoverLostMirror() {
                    await engine.resetShadow()
                }
                // Removals made since the last pass go first, so the pull's
                // repair of rows deleted without one can't bring them back.
                await Self.recordRemovals(deletionLog, to: backend)
                do {
                    try await backend.pull()
                } catch {
                    Logger.sync.error("Sync pull failed: \(error)")
                }
                let result = await engine.reconcile()
                await Self.recordRemovals(deletionLog, to: backend)
                do {
                    try await backend.push()
                } catch {
                    Logger.sync.error("Sync push failed: \(error)")
                }
                return result
            }
            // Back on the main actor (this closure is main-actor isolated).
            status.lastReconcile = Date()
            status.lastResult = result
            if backend is LumeCloudBackend {
                endLaunchJoinWait(openingGate: true)
            }

            isReconciling = false
            passTask = nil
            if pendingReconcile {
                // A waiting engine swap runs the queued pass once it's done.
                guard pendingEngineSwaps == 0 else { return }
                runQueuedReconcile()
            } else if shouldOpenInitialSyncGate, !status.hasCompletedInitialSync {
                // Open the gate only after the last queued pass, so imported
                // playlists are fully materialised before the form decision.
                status.hasCompletedInitialSync = true
            }
        }
    }

    /// Hands the rows deleted on purpose since the last drain to `backend`.
    private static func recordRemovals(_ log: SyncMirrorDeletionLog, to backend: any SyncBackend) async {
        let keys = log.drain()
        guard !keys.isEmpty else { return }
        await backend.recordRemovals(logicalKeys: keys)
    }

    // MARK: - Engine swap

    /// Rebuild the engine over `mirrorContainer` with the shadow namespace
    /// `namespace`. Waits for the in-flight pass, so no pass ever runs on the old
    /// and the new engine at once; passes requested meanwhile run afterwards on
    /// the new engine. When swaps overlap, the last one requested wins. The
    /// registered mirror consumers are repointed along with the engine.
    /// `resettingShadow` empties the new engine's baseline, so its first pass is
    /// a union merge that can't read anything as deleted.
    func replaceEngine(
        mirrorContainer: ModelContainer,
        namespace: SyncBackendKind,
        resettingShadow: Bool = false,
        defaults: UserDefaults? = nil
    ) async {
        engineSwapGeneration += 1
        let generation = engineSwapGeneration
        pendingEngineSwaps += 1
        await waitForPass()
        if generation == engineSwapGeneration {
            engine = Self.makeEngine(
                catalogContainer: catalogContainer,
                mirrorContainer: mirrorContainer,
                namespace: namespace,
                resettingShadow: resettingShadow,
                defaults: defaults ?? self.defaults,
                deletionLog: deletionLog
            )
            engineNamespace = namespace
            self.mirrorContainer = mirrorContainer
            repointMirrorConsumers(to: mirrorContainer)
        }
        resumePasses()
    }

    /// Holds new passes back and waits out the in-flight one, so the backend
    /// and the engine can change under no pass. Pair with `resumePasses()`.
    func suspendPasses() async {
        pendingEngineSwaps += 1
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = nil
        await waitForPass()
    }

    /// Ends a `suspendPasses()`; runs a pass requested meanwhile.
    func resumePasses() {
        pendingEngineSwaps -= 1
        guard pendingEngineSwaps == 0, pendingReconcile else { return }
        runQueuedReconcile()
    }

    /// Runs the pass queued behind a pass or an engine swap; a queued
    /// background flush skips the debounce, which could outlast the app's
    /// background time.
    private func runQueuedReconcile() {
        pendingReconcile = false
        let isFlush = pendingReconcileIsFlush
        pendingReconcileIsFlush = false
        reconcile(debounced: !isFlush)
    }

    /// Keeps the app awake until the background flush and any pass queued
    /// behind it have finished: each pass holds its own assertion, but the
    /// hand-off between two would otherwise leave a gap to suspend in.
    private func holdBackgroundTimeForFlush() async {
        await BackgroundActivity.perform("Sync background flush") {
            await waitForPass()
        }
    }

    func waitForPass() async {
        while let pass = passTask {
            await pass.value
        }
    }

    /// Makes `next` the active backend. Only the backend switch calls this,
    /// between `suspendPasses()` and `resumePasses()`, after stopping the old one.
    func install(_ next: any SyncBackend) {
        register(next)
        backend = next
        status.backend = SyncBackendSelection(next.kind)
        status.lastError = nil
        next.attach(to: self)
        updateEventListening()
        if next.kind != nil {
            observeContentSyncCompletion()
        }
    }

    /// Lume Cloud's socket follows the scene: open while active, closed otherwise.
    private func updateEventListening() {
        backend.setListensForEvents(isSceneActive)
    }

    func register(_ backend: any SyncBackend) {
        backends[SyncBackendSelection(backend.kind)] = backend
        backend.observeAccountEnd { [weak self] reason in
            Task { await self?.handleAccountEnded(reason) }
        }
    }

    private static func makeEngine(
        catalogContainer: ModelContainer,
        mirrorContainer: ModelContainer,
        namespace: SyncBackendKind,
        resettingShadow: Bool = false,
        defaults: UserDefaults,
        deletionLog: SyncMirrorDeletionLog
    ) -> CloudSyncEngine {
        let shadow = CloudSyncShadow(defaults: defaults, namespace: namespace)
        if resettingShadow {
            shadow.resetAll()
        }
        return CloudSyncEngine(
            catalogContainer: catalogContainer,
            cloudContainer: mirrorContainer,
            shadow: shadow,
            deletionLog: deletionLog
        )
    }

    // MARK: - Mirror consumers

    /// Register a reader of the mirror store to follow engine swaps. Held weakly.
    func addMirrorConsumer(_ consumer: any SyncMirrorConsumer) {
        mirrorConsumers.removeAll { $0.value == nil || $0.value === consumer }
        mirrorConsumers.append(WeakMirrorConsumer(value: consumer))
    }

    private func repointMirrorConsumers(to container: ModelContainer) {
        mirrorConsumers.removeAll { $0.value == nil }
        for consumer in mirrorConsumers {
            consumer.value?.repoint(container: container)
        }
    }

    /// A backend wrote rows into the mirror itself (`.lumeSyncMirrorDidChange`),
    /// or a profile was deleted from it.
    func notifyMirrorConsumers() {
        mirrorConsumers.removeAll { $0.value == nil }
        for consumer in mirrorConsumers {
            consumer.value?.mirrorDidChange()
        }
    }

    // MARK: - Playlist deletion

    /// The user deleted a playlist: propagate it through the engine (cloud
    /// mirror + shadow + local catalog) as one actor-serialized operation, so
    /// deleting the last playlist can't be misread by the empty-store
    /// integrity gate and resurrected from the surviving mirror (#136).
    /// Under Lume Cloud the deletion also queues explicit tombstones, the only
    /// way a deletion reaches the server. With sync Off only the local catalog
    /// changes: Off writes to no mirror.
    func deletePlaylist(id: UUID) async {
        do {
            if backend.kind == nil {
                try await engine.deleteCatalogPlaylist(id: id)
            } else {
                try await engine.deletePlaylist(id: id)
            }
        } catch {
            Logger.sync.error("Playlist deletion failed: \(error.localizedDescription)")
            return
        }
        await backend.recordPlaylistDeletion(id: id)
    }

    // MARK: - Initial-sync gate

    /// The backend judged its launch-time sync settled: open the gate that a
    /// fresh install waits on. Triggers a reconcile first (so cloud playlists
    /// already imported become local `Playlist` records), then opens the gate
    /// when it finishes — letting `ContentView` show the main app if playlists
    /// arrived, or fall back to the add-playlist form if not. Idempotent: only
    /// the first call has any effect.
    func backendDidSettleInitialSync() {
        guard !status.hasCompletedInitialSync, !shouldOpenInitialSyncGate else { return }
        shouldOpenInitialSyncGate = true
        // Lume Cloud settles after the running pass's pull, which that pass
        // then reconciles; its completion opens the gate.
        guard !(isReconciling && backend is LumeCloudBackend) else { return }
        reconcile(reason: .launch)
    }

    /// The user tapped "Continue Without Syncing" on the launch screen: stop
    /// waiting and fall through to the add-playlist form. Sync keeps running in
    /// the background, so cloud playlists still appear if they arrive later.
    func skipInitialSyncWait() {
        status.hasCompletedInitialSync = true
        endLaunchJoinWait(openingGate: false)
    }

    // MARK: - Account status

    func refreshAccountStatus() async {
        await backend.refreshStatus()
    }

    // MARK: - Store observers

    /// After a playlist's catalog finishes syncing, run a reconcile so any cloud
    /// user state that was waiting for that catalog gets applied.
    private func observeContentSyncCompletion() {
        guard !observesContentSync else { return }
        observesContentSync = true
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

extension CloudSyncCoordinator: SyncBackendHost {}

extension Notification.Name {
    /// Posted by `ContentSyncManager` after a playlist's catalog sync succeeds.
    static let lumeContentSyncDidComplete = Notification.Name("LumeContentSyncDidComplete")
    /// Posted on the main actor, with no object, after a backend wrote rows
    /// into the mirror store itself (a pull, a conflict merge or a recorded
    /// deletion). CloudKit's own writes post `.NSPersistentStoreRemoteChange`.
    static let lumeSyncMirrorDidChange = Notification.Name("LumeSyncMirrorDidChange")
}
