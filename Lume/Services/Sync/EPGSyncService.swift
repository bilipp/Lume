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
        return playlists.contains { playlist in
            AutoSync.blocksEPGRefresh(
                syncEnabled: playlist.syncEnabled,
                status: playlist.syncStatus,
                lastSyncDate: playlist.lastSyncDate,
                frequency: frequency
            )
        }
    }

    private var isDue: Bool {
        let raw = UserDefaults.standard.string(forKey: SyncFrequency.epgStorageKey) ?? ""
        let frequency = SyncFrequency.resolveEPG(raw)
        return frequency.isDue(lastSyncDate: EPGSyncSchedule.lastSyncDate)
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
            }
            isSyncing = false
            task = nil
            Logger.database.info("EPG refresh finished (success: \(succeeded))")
        }
    }
}
