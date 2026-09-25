//
//  EPGSyncService.swift
//  Lume
//
//  Owns the background EPG refresh task and publishes whether one is running,
//  for the EPG settings screen. Singleton because it must outlive any one view
//  and be reachable from launch, the content-sync completion hook, and the
//  manual "Sync Now" button.
//

import Foundation
import Observation
import OSLog
import SwiftData

/// When a background guide refresh may run, given the playlist content syncs
/// around it. Pure so the ordering can be unit-tested; `EPGSyncService` owns
/// the one instance and feeds it.
///
/// Both downloads hit the same provider account, and Xtream panels commonly
/// cap an account at one concurrent connection — a guide download racing the
/// catalog sync gets one of the two rejected (and can leave the account
/// briefly blocked, failing the sync's next requests too). So the gate is fed
/// the real state from the places that own it, rather than predicting which
/// sync is about to start: `MainTabView` reports whether its auto-sync queue
/// holds anything, and `SyncProgressView` — the one place any content sync
/// runs — reports each start and finish.
struct EPGRefreshGate {
    /// Content syncs running right now, automatic or manual.
    private(set) var runningContentSyncs = 0
    /// Whether auto-syncs are queued or on screen in the blocking cover.
    var isAutoSyncQueued = false
    /// A background refresh that was held back or cut short, run as soon as no
    /// content sync is pending. Set by any deferred trigger and by every
    /// successful sync — a freshly synced playlist's channels shouldn't wait
    /// for the next scheduled run.
    private(set) var isRefreshOwed = false

    var isContentSyncPending: Bool {
        runningContentSyncs > 0 || isAutoSyncQueued
    }

    /// A background trigger asking to refresh. Returns whether it may start
    /// now; otherwise the refresh is owed.
    mutating func request() -> Bool {
        isRefreshOwed = isContentSyncPending
        return !isRefreshOwed
    }

    /// A refresh was cut short and has to run again.
    mutating func owe() {
        isRefreshOwed = true
    }

    mutating func contentSyncStarted() {
        runningContentSyncs += 1
    }

    /// Every start is paired with one finish, whether the sync succeeded,
    /// failed or was aborted. Only success owes a refresh of its own; a failed
    /// or aborted one still releases anything held back while it ran.
    mutating func contentSyncFinished(succeeded: Bool) {
        runningContentSyncs = max(0, runningContentSyncs - 1)
        if succeeded { isRefreshOwed = true }
    }

    /// Whether an owed refresh may start now. Clears the debt when it does.
    mutating func takeOwedRefresh() -> Bool {
        guard isRefreshOwed, !isContentSyncPending else { return false }
        isRefreshOwed = false
        return true
    }
}

@Observable
final class EPGSyncService {
    static let shared = EPGSyncService()

    private(set) var isSyncing = false

    private var container: ModelContainer?
    private var task: Task<Void, Never>?
    /// Whether `task` is a background refresh, which a starting content sync
    /// cancels — rather than a manual "Sync Now", which the viewer asked for.
    @ObservationIgnored private var isBackgroundRefresh = false
    @ObservationIgnored private var gate = EPGRefreshGate()

    /// Latched once `hasSubtitleData` first sees a `<sub-title>`: listings only ever
    /// gain sub-titles (a guide refresh adds them; nothing strips them), so a
    /// confirmed `true` never needs the table re-scanned on later hub opens.
    private var subtitleDataConfirmed = false

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Manual trigger (settings "Sync Now"): refreshes now regardless of the
    /// schedule or any in-flight content sync.
    func syncNow() {
        kick()
    }

    /// Background trigger (launch): refreshes only if the guide is stale per
    /// the EPG frequency setting — and never alongside a pending playlist sync
    /// (see `EPGRefreshGate`). A deferred refresh runs once the sync is done.
    func syncIfDue() {
        guard isDue, gate.request() else { return }
        kick(background: true)
    }

    /// The Sports Hub matches fixtures against programme sub-titles; a guide
    /// imported before those were kept matches poorly. Refresh it once per
    /// launch when no listing carries a sub-title, rather than telling the
    /// viewer to. Returns whether a refresh was started.
    @discardableResult
    func refreshIfMissingSubtitles() async -> Bool {
        guard !didRefreshForSubtitles else { return false }
        if await hasSubtitleData() { return false }
        guard !isSyncing else { return false }
        // A deferred request still counts: the owed refresh brings the
        // sub-titles in as soon as the pending sync is done.
        didRefreshForSubtitles = true
        guard gate.request() else { return false }
        kick(background: true)
        return true
    }

    private var didRefreshForSubtitles = false

    // MARK: - Content sync reports

    /// `MainTabView`'s auto-sync queue went from empty to busy or back.
    func setAutoSyncQueued(_ queued: Bool) {
        gate.isAutoSyncQueued = queued
        runOwedRefresh()
    }

    /// A playlist content sync is starting. A background refresh already in
    /// flight is cancelled and owed rather than left to race it — the guide may
    /// have started first (at launch, or before the viewer switched to a stale
    /// playlist), and the gate alone only keeps it from starting second.
    func contentSyncDidStart() {
        gate.contentSyncStarted()
        if let task, isBackgroundRefresh {
            task.cancel()
            gate.owe()
        }
    }

    /// The content sync reported by `contentSyncDidStart` ended, however it
    /// ended.
    func contentSyncDidFinish(succeeded: Bool) {
        gate.contentSyncFinished(succeeded: succeeded)
        runOwedRefresh()
    }

    private func runOwedRefresh() {
        // `container` first: taking the debt before `configure` would drop it.
        guard container != nil, task == nil, gate.takeOwedRefresh() else { return }
        kick(background: true)
    }

    private var isDue: Bool {
        // A guide-schema bump (new XMLTV signals to capture) forces one refresh
        // regardless of the frequency, so existing users back-fill the new
        // columns on their next launch.
        if EPGSyncSchedule.schemaVersion < SyncFrequency.epgCurrentSchemaVersion { return true }
        let raw = UserDefaults.standard.string(forKey: SyncFrequency.epgStorageKey) ?? ""
        let frequency = SyncFrequency.resolveEPG(raw)
        return frequency.isDue(lastSyncDate: EPGSyncSchedule.lastSyncDate)
    }

    /// Cheap probe for whether any ingested listing carries a `<sub-title>` — the
    /// signal the Sports Hub's first-run hint keys off ("channel matching
    /// improves after your next guide refresh"). Runs the `fetchLimit(1)` fetch
    /// off the main actor so a hub open never blocks on it.
    func hasSubtitleData() async -> Bool {
        if subtitleDataConfirmed { return true }
        guard let container else { return false }
        let found = await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<EPGListing>(
                predicate: #Predicate { $0.subtitle != nil }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.subtitle]
            let results = (try? context.fetch(descriptor)) ?? []
            return !results.isEmpty
        }.value
        if found { subtitleDataConfirmed = true }
        return found
    }

    private func kick(background: Bool = false) {
        guard let container, task == nil else { return }
        isSyncing = true
        isBackgroundRefresh = background
        let manager = EPGSyncManager(modelContainer: container)
        // Background guide refresh: run below the UI so an in-flight sync (which
        // saves into the shared catalog container, churning browse `@Query`s)
        // yields CPU to the main thread instead of competing with it. The
        // profile showed EPG ingest pegging a background thread at 100% in
        // lockstep with a frozen main thread right after a playlist sync.
        task = Task(priority: .utility) {
            let succeeded = await manager.syncAllSources()
            if succeeded {
                EPGSyncSchedule.lastSyncDate = Date()
                EPGSyncSchedule.schemaVersion = SyncFrequency.epgCurrentSchemaVersion
            }
            isSyncing = false
            task = nil
            Logger.database.info("EPG refresh finished (success: \(succeeded))")
            // A refresh cancelled for a content sync may wind down after that
            // sync already finished and found this task still set.
            runOwedRefresh()
        }
    }
}
