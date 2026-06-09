import Foundation
import OSLog
import SwiftData

// MARK: - Crash recovery

extension ContentSyncManager {
    /// Resets any playlist left in `.syncing` by a previous session that died
    /// mid-sync (tvOS suspends then terminates background apps aggressively, and
    /// a crash has the same effect).
    ///
    /// `.syncing` is a runtime-only state: the only thing that sets it is a live
    /// in-process task tracked in `activeSyncTasks`, which cannot survive a
    /// process launch. So a `.syncing` status observed at startup is by
    /// definition stale. Left untouched it wedges the playlist permanently —
    /// `AutoSync.shouldSync` skips anything already `.syncing`, so no further
    /// auto-sync ever fires and the blocking progress cover (driven by in-memory
    /// state) never reappears, while Settings keeps showing "Syncing" forever.
    ///
    /// Call once at launch, before the auto-sync gate reads playlist status.
    static func recoverInterruptedSyncs(in context: ModelContext) {
        let syncingRaw = SyncStatus.syncing.rawValue
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.syncStatusRaw == syncingRaw }
        )
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }

        for playlist in stuck {
            playlist.syncStatus = .idle
        }
        try? context.save()
        Logger.database.info("Recovered \(stuck.count) playlist(s) stuck in .syncing from a previous session")
    }
}

// MARK: - Helper Methods

extension ContentSyncManager {
    func markPlaylistError(playlistId: UUID) {
        let errContext = ModelContext(modelContainer)
        errContext.autosaveEnabled = false
        if let epl = try? errContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            epl.syncStatus = .error
            try? errContext.save()
        }
    }

    func updatePlaylistInfo(_ playlistId: UUID, with authResponse: XtreamAuthResponse) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        playlist.userStatus = authResponse.userInfo.status
        playlist.maxConnections = authResponse.userInfo.maxConnections
        playlist.activeConnections = authResponse.userInfo.activeCons
        playlist.expDate = authResponse.userInfo.expDate
        playlist.serverTimezone = authResponse.serverInfo.timezone
        playlist.lastUpdated = Date()
        try? context.save()
    }

    func buildExistingCategoryLookup(context: ModelContext, playlistId: UUID, type: CategoryType) -> [String: Category] {
        let prefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let typeRaw = type.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.typeRaw == typeRaw }
        )
        guard let allCategories = try? context.fetch(descriptor) else { return [:] }
        var lookup: [String: Category] = [:]
        lookup.reserveCapacity(allCategories.count)
        for category in allCategories where category.id.hasPrefix(prefix) {
            lookup[category.apiId] = category
        }
        return lookup
    }
}
