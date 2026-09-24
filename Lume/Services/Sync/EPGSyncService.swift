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

@Observable
final class EPGSyncService {
    static let shared = EPGSyncService()

    private(set) var isSyncing = false

    private var container: ModelContainer?
    private var task: Task<Void, Never>?

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
    /// the EPG frequency setting — and never alongside a running or imminent
    /// playlist sync. The guide download would open a second connection to the
    /// provider, tripping the one-connection account cap many Xtream panels
    /// enforce and failing both the guide and the sync's content requests.
    /// `syncAfterContentSync` re-kicks the refresh once the sync queue drains.
    func syncIfDue() {
        guard isDue, !isContentSyncPending else { return }
        kick()
    }

    /// Background trigger after a playlist sync finishes: refreshes regardless
    /// of the schedule — a freshly synced playlist's channels shouldn't wait
    /// for the next scheduled run — but still stands aside while another
    /// playlist sync is due (this hook fires again when that one completes).
    func syncAfterContentSync() {
        guard !isContentSyncPending else { return }
        kick()
    }

    /// The Sports Hub matches fixtures against programme sub-titles; a guide
    /// imported before those were kept matches poorly. Refresh it once per
    /// launch when no listing carries a sub-title, rather than telling the
    /// viewer to. Returns whether a refresh was started.
    @discardableResult
    func refreshIfMissingSubtitles() async -> Bool {
        guard !didRefreshForSubtitles else { return false }
        if await hasSubtitleData() { return false }
        guard !isSyncing, !isContentSyncPending else { return false }
        didRefreshForSubtitles = true
        kick()
        return true
    }

    private var didRefreshForSubtitles = false

    /// Whether any playlist's content sync is running or due to start, meaning
    /// a background guide refresh would compete with it for the provider's
    /// connection allowance.
    private var isContentSyncPending: Bool {
        guard let container else { return false }
        let frequency = SyncFrequency.resolve(
            UserDefaults.standard.string(forKey: SyncFrequency.storageKey) ?? ""
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        // Auto-sync only runs for the playlist on screen (plus any that has
        // never synced), so the guide has to read the same selection to know
        // which of these is actually about to start.
        let activeID = playlists.activeID(
            for: UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? ""
        )
        return playlists.contains { playlist in
            AutoSync.blocksEPGRefresh(
                AutoSync.Candidate(
                    syncEnabled: playlist.syncEnabled,
                    status: playlist.syncStatus,
                    lastSyncDate: playlist.lastSyncDate,
                    isActive: playlist.id.uuidString == activeID
                ),
                frequency: frequency
            )
        }
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

    private func kick() {
        guard let container, task == nil else { return }
        isSyncing = true
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
        }
    }
}
