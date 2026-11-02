//
//  CloudSyncEngine+Episodes.swift
//  Lume
//
//  Synced watch state for episodes that just materialized. Xtream, Stalker and
//  per-show media servers list a series' episodes only when it opens, so the
//  cloud state for them waits in the mirror. A reconcile would apply it, but
//  none runs when a series opens, and the episodes read unwatched until the
//  next launch or background flush.
//

import Foundation
import OSLog
import SwiftData

extension CloudSyncEngine {
    /// Applies the active profile's cloud state to the episodes `ids` names,
    /// which `Series.insertEpisodes` just created, and baselines the shadow on
    /// it. Returns how many episodes took a state.
    ///
    /// A new row has no state of its own, so the cloud value wins whatever
    /// the shadow holds. A full reconcile would read a re-created row (a series
    /// pruned and back) against an old baseline as the user clearing it, and
    /// delete the record on every device. An episode played since it was
    /// inserted is left to the reconcile's merge.
    @discardableResult
    func applyCloudState(toNewEpisodes ids: [String]) -> Int {
        guard !ids.isEmpty, case .ready = localCatalogReadiness() else { return 0 }
        activeProfileID = ActiveProfileStore.current ?? UserProfile.defaultProfileID
        do {
            let mirrors = try episodeMirrors(ids)
            guard !mirrors.isEmpty else { return 0 }
            let wanted = Array(mirrors.keys)
            let episodes = try catalogContext.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate { wanted.contains($0.id) }
            ))
            var applied = 0
            for episode in episodes where episode.watchProgress == 0 && !episode.isWatched {
                guard let mirror = mirrors[episode.id] else { continue }
                let values = Self.values(from: mirror)
                episode.watchProgress = values.watchProgress
                episode.isWatched = values.isWatched
                episode.lastWatchedDate = values.lastWatchedDate
                shadow.setContentShadow(episode.id, values)
                applied += 1
            }
            guard applied > 0 else { return 0 }
            try saveStores()
            shadow.persist()
            Logger.sync.info("Applied synced state to \(applied) new episode(s)")
            return applied
        } catch {
            Logger.sync.error("Applying synced state to new episodes failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// The active profile's episode mirrors among `ids`, keyed by content id.
    private func episodeMirrors(_ ids: [String]) throws -> [String: UserContentState] {
        let profileID = activeProfileID
        let includeUnclaimed = profileID == UserProfile.defaultProfileID
        let episodeKind = SyncedContentKind.episode.rawValue
        let descriptor = FetchDescriptor<UserContentState>(predicate: #Predicate {
            ids.contains($0.contentId) && $0.kindRaw == episodeKind
                && ($0.profileID == profileID || ($0.profileID == nil && includeUnclaimed))
        })
        var map: [String: UserContentState] = [:]
        for mirror in try cloudContext.fetch(descriptor) {
            map[mirror.contentId] = dedupe(mirror, against: map[mirror.contentId])
        }
        return map.filter { !$0.value.isEmptyState }
    }
}

private extension UserContentState {
    /// A record whose every field is at its default: nothing to apply.
    var isEmptyState: Bool {
        CloudSyncEngine.values(from: self).isEmpty
    }
}
