//
//  ContentSyncManager+CatalogHistory.swift
//  Lume
//
//  Reclaiming the persistent history the catalog store writes and nothing
//  reads. Called from `performSync` for every source. Its own file because
//  ContentSyncManager+M3U.swift sits against SwiftLint's file-length limit.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// Name of the CloudKit mirror's `ModelConfiguration` — the app's only named
    /// configuration, stamped in `LumeApp.makeCloudContainer()`.
    static let cloudMirrorConfigurationName = "CloudUserData"

    /// Whether persistent history may be deleted from a container holding
    /// `configurations`. False for the CloudKit mirror, which tracks what it
    /// still owes the server through exactly that history.
    nonisolated static func historyPurgeIsSafe(for configurations: some Collection<ModelConfiguration>) -> Bool {
        configurations.allSatisfy {
            $0.name != cloudMirrorConfigurationName && $0.cloudKitContainerIdentifier == nil
        }
    }

    /// Deletes the catalog store's persistent history.
    ///
    /// SwiftData records history unconditionally: this SDK's
    /// `ModelConfiguration` exposes no history switch (only `allowsSave`,
    /// `isStoredInMemoryOnly`, `groupContainer` and `cloudKitDatabase`), so a
    /// cold catalog import — m3u, Xtream or Stalker — writes one indexed
    /// `ACHANGE` row per catalog row inside the very `save()` calls the import
    /// cost is concentrated in. Nothing in Lume ever reads it back — there is no `HistoryDescriptor`,
    /// `HistoryToken` or `fetchHistory` anywhere in the app.
    ///
    /// IRREVERSIBLE. A future catalog change-history feature (an
    /// extension-driven incremental refresh, a "what changed since" view)
    /// cannot be built on top of this call — it would have to stop making it.
    /// Safe today because `default.store` has exactly one client: the app
    /// process. `LumeWidgets` links no SwiftData, and the mirror lives in its
    /// own container — so there is no peer holding a history token this drops
    /// changes out from under.
    ///
    /// Purging history on the CloudKit-mirror container would be a sync bug:
    /// `NSPersistentCloudKitContainer` tracks what it still owes the server
    /// through exactly this history. That is structural here rather than a rule
    /// to remember — the method takes no container and reads the actor's own,
    /// which is always the catalog container (`CloudUserData.store` is reached
    /// only through `CloudSyncEngine`, never through a `ContentSyncManager`).
    /// `historyPurgeIsSafe(for:)` is the belt to that braces, and it keys on the
    /// mirror's configuration name rather than on `cloudKitContainerIdentifier`
    /// alone: that identifier is nil for the mirror too in every un-entitled
    /// build (tests, previews, sideload), so on its own it proves nothing.
    ///
    /// Only reached from `performSync` once the source-specific sync has
    /// returned without throwing, so a cancelled or failed sync purges nothing.
    /// Carries its own signpost interval because the call site is a bare
    /// statement there — `ContentSyncManager.swift` is at SwiftLint's
    /// file-length limit.
    func purgeCatalogHistory() {
        let interval = Perf.begin(.catalogPurgeHistory)
        defer { Perf.end(interval) }
        guard Self.historyPurgeIsSafe(for: modelContainer.configurations) else {
            Logger.database.error("Refusing to purge persistent history: container holds the CloudKit mirror")
            return
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            try context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            try context.save()
        } catch {
            // Best effort: a finished import must not be reported as failed
            // because reclaiming its history didn't take.
            let message = error.localizedDescription
            Logger.database.error("Persistent history purge failed: \(message, privacy: .public)")
        }
    }
}
