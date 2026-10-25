import Foundation
import SwiftData

/// The one-time "watched" push to every connected tracker, shared by the
/// full-screen player and the commit of a cast that ended after its player
/// closed.
enum WatchedServicesSync {
    /// Runs at most once per title (when it crosses 90%), so the fetch on
    /// `context` is off the playback hot path. The services are `@MainActor`,
    /// hence this is too.
    static func sync(ref: PlayableMedia.ContentRef, in context: ModelContext) {
        switch ref {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? context.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(movie: movie, watched: true)
            SimklService.shared.syncWatched(movie: movie, watched: true)
        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(episode: episode, watched: true)
            SimklService.shared.syncWatched(episode: episode, watched: true)
        case .live, .recording:
            break
        }
    }
}
