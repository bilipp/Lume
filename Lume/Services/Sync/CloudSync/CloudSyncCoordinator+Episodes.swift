//
//  CloudSyncCoordinator+Episodes.swift
//  Lume
//
//  Episodes a series lists only when it opens (`Series.insertEpisodes`) take
//  their synced watch state at once, instead of at the next pass.
//

import Foundation

extension CloudSyncCoordinator {
    /// Observes `.lumeEpisodesDidMaterialize` for as long as the coordinator
    /// lives (the whole process).
    func observeNewEpisodes() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .lumeEpisodesDidMaterialize,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let ids = notification.userInfo?[Notification.episodeIDsKey] as? [String] ?? []
            MainActor.assumeIsolated {
                self?.applySyncedState(toNewEpisodes: ids)
            }
        })
    }

    /// Hands the new episodes to the engine, which applies the active
    /// profile's synced state to them. Sync Off writes no mirror, so it has
    /// none to apply.
    func applySyncedState(toNewEpisodes ids: [String]) {
        guard backend.kind != nil, !ids.isEmpty else { return }
        let engine = engine
        Task {
            await BackgroundActivity.perform("Apply synced episode state") {
                await engine.applyCloudState(toNewEpisodes: ids)
            }
        }
    }
}

extension Notification.Name {
    /// Posted on the main actor by `Series.insertEpisodes` with the ids of the
    /// episodes it created, under `Notification.episodeIDsKey`.
    static let lumeEpisodesDidMaterialize = Notification.Name("LumeEpisodesDidMaterialize")
}

extension Notification {
    /// `[String]` of `Episode.id`s in a `.lumeEpisodesDidMaterialize` post.
    static let episodeIDsKey = "episodeIDs"
}
