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

    /// Drops the whole reconcile baseline, so the next pass is a union merge of
    /// catalog and mirror that can't read anything as deleted. For a mirror
    /// store that was lost and comes back empty.
    func resetShadow() {
        shadow.resetAll()
    }

    func localCatalogReadiness() -> LocalCatalogReadiness {
        let counts: [Int]
        do {
            counts = try [
                catalogContext.fetchCount(FetchDescriptor<Playlist>()),
                catalogContext.fetchCount(FetchDescriptor<Movie>()),
                catalogContext.fetchCount(FetchDescriptor<Series>()),
                catalogContext.fetchCount(FetchDescriptor<Episode>()),
                catalogContext.fetchCount(FetchDescriptor<LiveStream>())
            ]
        } catch {
            Logger.sync.error("Local catalog unreadable (\(error.localizedDescription, privacy: .public)) — skipping reconcile, not pushing deletions to iCloud")
            return .unreadable
        }
        let shadowHasBaseline = !shadow.playlistShadowIDs().isEmpty || !shadow.contentShadowIDs().isEmpty
        let readiness = Self.readiness(counts: counts, shadowHasBaseline: shadowHasBaseline)
        if readiness == .unreadable {
            Logger.sync.error("Local catalog returned an invalid count — skipping reconcile, not pushing deletions to iCloud")
        }
        return readiness
    }

    /// Classifies the probe counts. Core Data can report a count of
    /// `NSNotFound` (`Int.max`) instead of throwing while a store is detached —
    /// seen after macOS sleep/wake — and summing that trapped on overflow
    /// (#256). A count outside `0..<NSNotFound` means the store didn't really
    /// answer, so it reads as `.unreadable`. The counts are only tested for
    /// zero, never added.
    static func readiness(counts: [Int], shadowHasBaseline: Bool) -> LocalCatalogReadiness {
        if counts.contains(where: { $0 < 0 || $0 >= NSNotFound }) {
            return .unreadable
        }
        if shadowHasBaseline, counts.allSatisfy({ $0 == 0 }) {
            return .emptiedButHadData
        }
        return .ready
    }
}
