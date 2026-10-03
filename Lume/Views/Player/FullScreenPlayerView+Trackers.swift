//
//  FullScreenPlayerView+Trackers.swift
//  Lume
//
//  The player's one-time "watched" push to Trakt and Simkl, split out of
//  `FullScreenPlayerView` to keep that file inside the 600-line cap.
//

import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// One-time "watched" sync to every connected tracker. Runs at most once per
    /// title (when it crosses 90%), so the main-context fetch here is off the
    /// playback hot path. The services are `@MainActor`, hence this stays on the
    /// main actor.
    func syncWatchedServices(ref: PlayableMedia.ContentRef) {
        switch ref {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? modelContext.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(movie: movie, watched: true)
            SimklService.shared.syncWatched(movie: movie, watched: true)
        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? modelContext.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(episode: episode, watched: true)
            SimklService.shared.syncWatched(episode: episode, watched: true)
        case .live:
            break
        }
    }
}
