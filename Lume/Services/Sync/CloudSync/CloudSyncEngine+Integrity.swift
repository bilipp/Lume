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

// MARK: - Mirror integrity

/// The mirror-side twin of the local gate above.
///
/// A mirror store can come up empty, or only partly imported, while the local
/// catalog and the shadow survive: CloudKit resets its history after an
/// `NSPersistentHistoryTokenExpiredError` (134301) and re-imports every record
/// from scratch, and a Lume Cloud mirror can be wiped and re-pulled. A reconcile
/// over that mirror reads every baselined record it hasn't re-imported yet as a
/// *deletion on another device*: it deletes the local playlists, the content
/// pass then garbage-collects their favorites, hidden channels and category
/// order, and those clears go out as deletions to every other device. That is
/// how a Mac lost its Live TV favorites for good while every other device still
/// had them.
extension CloudSyncEngine {
    enum MirrorReadiness: Equatable {
        /// The mirror holds what the shadow says it held — reconcile normally.
        case ready
        /// The mirror lost records the shadow baselined, in a shape no
        /// legitimate edit on another device produces. Reconcile as a union
        /// merge so nothing is read as deleted.
        case lostButHadData
    }

    /// What the probe saw, kept apart from the store so the classifier is a pure
    /// function with its own tests.
    nonisolated struct MirrorProbe: Equatable {
        /// Playlists in both the shadow and the local catalog: the ones the
        /// mirror held at the last pass and this device still has.
        var baselinedPlaylists = 0
        /// Of those, the ones the mirror no longer holds.
        var missingPlaylists = 0
        /// Whether the mirror holds any `UserProfile` row. Every device that
        /// ever reconciled wrote one, so a mirror without any is a mirror that
        /// came back empty.
        var mirrorHasProfiles = true
        /// Content states in the shadow (favorites, progress, hidden, order)
        /// whose playlist the mirror still holds. A playlist deleted on another
        /// device takes its states with it, so those don't count.
        var baselinedContent = 0
        /// Content-state rows the mirror holds, across every profile.
        var mirrorContent = 0
    }

    /// Classifies a mirror probe.
    ///
    /// Another device deletes playlists one at a time and un-favorites items one
    /// at a time, so each signature below asks for more than any ordinary edit:
    /// - every baselined playlist gone at once, when there were at least two of
    ///   them or the profiles went with them (a single-playlist user deleting it
    ///   elsewhere still propagates — their profile row survives);
    /// - at least three playlists and most of them gone at once;
    /// - every content state gone while the shadow held at least three for
    ///   playlists the mirror still has.
    ///
    /// A false positive costs one union merge: a remote deletion is undone and
    /// can be repeated. A false negative wipes the device and every device after
    /// it, so the thresholds lean towards the union merge.
    static func mirrorReadiness(_ probe: MirrorProbe) -> MirrorReadiness {
        let baselined = probe.baselinedPlaylists
        let missing = probe.missingPlaylists
        if missing > 0, missing == baselined, baselined >= 2 || !probe.mirrorHasProfiles {
            return .lostButHadData
        }
        if missing >= 3, missing * 2 > baselined {
            return .lostButHadData
        }
        if probe.baselinedContent >= 3, probe.mirrorContent == 0 {
            return .lostButHadData
        }
        return .ready
    }

    /// Drops the whole baseline when the mirror lost what it held, so the pass
    /// that follows is a union merge. Returns whether it did.
    func recoverFromLostMirror() -> Bool {
        guard mirrorReadiness() == .lostButHadData else { return false }
        resetShadow()
        return true
    }

    /// Reads the mirror against the shadow and the local catalog. A probe fetch
    /// that throws reads as `.ready`: the reconcile's own fetches will throw too
    /// and abort the pass before anything is written.
    func mirrorReadiness() -> MirrorReadiness {
        do {
            let shadowPlaylists = Set(shadow.playlistShadowIDs().compactMap(UUID.init(uuidString:)))
            let baselined = try shadowPlaylists.intersection(fetchLocalPlaylists().keys)
            let mirrored = try Set(fetchPlaylistMirrors().keys)
            let mirroredPrefixes = Set(mirrored.map(\.uuidString))
            let probe = try MirrorProbe(
                baselinedPlaylists: baselined.count,
                missingPlaylists: baselined.subtracting(mirrored).count,
                mirrorHasProfiles: cloudContext.fetchCount(FetchDescriptor<UserProfile>()) > 0,
                baselinedContent: shadow.contentShadowIDs().count { mirroredPrefixes.contains(String($0.prefix(36))) },
                mirrorContent: cloudContext.fetchCount(FetchDescriptor<UserContentState>())
            )
            let readiness = Self.mirrorReadiness(probe)
            if readiness == .lostButHadData {
                Logger.sync.error("Sync mirror lost baselined records (playlists \(probe.missingPlaylists)/\(probe.baselinedPlaylists), content \(probe.mirrorContent)/\(probe.baselinedContent), profiles \(probe.mirrorHasProfiles)) — dropping stale shadow, merging without deletions") // swiftlint:disable:this line_length
            }
            return readiness
        } catch {
            return .ready
        }
    }
}
