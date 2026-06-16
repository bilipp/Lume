import Foundation
import OSLog
import SwiftData

/// The local-store integrity gate: the guard against catastrophic, cross-device
/// data loss. Split out of `CloudSyncEngine.swift` to keep that file within the
/// project's size limit.
///
/// If the local catalog store is unreadable or has come up empty (a
/// missing/recreated `default.store`, or a transient `no such table` detach
/// while `NSPersistentCloudKitContainer` re-adds stores on the shared
/// coordinator), a naive reconcile would read every absent local item as a
/// *user deletion* and push those deletions to the CloudKit mirrors — wiping the
/// data on every synced device. `reconcile()` consults this before mutating
/// anything.
extension CloudSyncEngine {
    /// The state of the local catalog store as a source of "local" truth.
    enum LocalCatalogReadiness {
        /// Catalog is readable with data (or legitimately empty on a fresh
        /// device, where the shadow is empty too) — reconcile normally.
        case ready
        /// A probe fetch threw: the store is mid-detach or corrupt. Skip the pass.
        case unreadable
        /// Catalog reads completely empty while the shadow baseline still holds
        /// playlists or content — a store that previously synced data cannot go
        /// empty in one legitimate step, so this is a lost/recreated store, not a
        /// mass deletion. Recover by re-pulling from the cloud.
        case emptiedButHadData
    }

    func localCatalogReadiness() -> LocalCatalogReadiness {
        let catalogCount: Int
        do {
            catalogCount = try catalogContext.fetchCount(FetchDescriptor<Playlist>())
                + catalogContext.fetchCount(FetchDescriptor<Movie>())
                + catalogContext.fetchCount(FetchDescriptor<Series>())
                + catalogContext.fetchCount(FetchDescriptor<Episode>())
                + catalogContext.fetchCount(FetchDescriptor<LiveStream>())
        } catch {
            Logger.sync.error("Local catalog unreadable (\(error.localizedDescription, privacy: .public)) — skipping reconcile, not pushing deletions to iCloud")
            return .unreadable
        }
        let shadowHasBaseline = !shadow.playlistShadowIDs().isEmpty || !shadow.contentShadowIDs().isEmpty
        if catalogCount == 0, shadowHasBaseline {
            return .emptiedButHadData
        }
        return .ready
    }
}
