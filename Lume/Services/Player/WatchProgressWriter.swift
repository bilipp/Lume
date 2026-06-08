import Foundation
import SwiftData

/// Persists VOD watch progress on a private background `ModelContext` so that
/// saving never runs on the main thread.
///
/// KSPlayer's render loop drops frames if a `ModelContext.save()` blocks the
/// main actor mid-playback — the periodic progress sampler used to do exactly
/// that every 5s. This actor owns its own context off the main thread (the same
/// pattern `ContentSyncManager` uses), so the player host only has to hand it a
/// few `Sendable` values; the fetch and the disk write happen here, away from
/// the render thread.
actor WatchProgressWriter {
    private let context: ModelContext

    /// The ref + progress of the most recent write, so the periodic sampler can
    /// skip redundant saves while playback is paused (the clock isn't moving).
    private var lastRef: PlayableMedia.ContentRef?
    private var lastProgress: TimeInterval = -1

    /// Surfaced when an item crosses the "watched" line on this write, so the
    /// caller can fire a one-time Trakt sync back on the main actor.
    struct Completion {
        let ref: PlayableMedia.ContentRef
    }

    init(container: ModelContainer) {
        context = ModelContext(container)
        // We flush explicitly after each mutation; autosave would add its own
        // unscheduled saves on top.
        context.autosaveEnabled = false
    }

    /// Commit any progress left in `WatchProgressBuffer` by a crashed/killed
    /// session into SwiftData. Runs once at launch, off the main thread, so the
    /// one resulting store merge happens before playback ever starts.
    static func reconcilePending(container: ModelContainer) async {
        let entries = WatchProgressBuffer.drain()
        guard !entries.isEmpty else { return }
        let writer = WatchProgressWriter(container: container)
        for entry in entries {
            await writer.record(
                ref: entry.contentRef,
                progress: entry.progress,
                duration: entry.duration,
                force: true
            )
        }
    }

    /// Write `progress` for `ref` and return a `Completion` if the item just
    /// became watched (≥ 90%). `force` bypasses the paused-playback dedup so
    /// the final save on close/switch always lands.
    @discardableResult
    func record(
        ref: PlayableMedia.ContentRef,
        progress: TimeInterval,
        duration: TimeInterval,
        force: Bool
    ) -> Completion? {
        guard progress > 0 else { return nil }

        // Reset dedup state when the active stream changes (in-player episode swaps).
        if ref != lastRef {
            lastRef = ref
            lastProgress = -1
        }
        if !force, progress == lastProgress { return nil }
        lastProgress = progress

        let completed = duration > 0 && progress / duration >= 0.9

        do {
            switch ref {
            case let .movie(id):
                return try writeMovie(id: id, progress: progress, completed: completed, ref: ref)
            case let .episode(id):
                return try writeEpisode(id: id, progress: progress, completed: completed, ref: ref)
            case let .live(id):
                try touchLive(id: id)
                return nil
            }
        } catch {
            // A dropped progress write is recoverable on the next tick; never
            // crash playback over it.
            return nil
        }
    }

    private func writeMovie(
        id: String,
        progress: TimeInterval,
        completed: Bool,
        ref: PlayableMedia.ContentRef
    ) throws -> Completion? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try context.fetch(descriptor).first else { return nil }

        movie.watchProgress = progress
        movie.lastWatchedDate = Date()

        var completion: Completion?
        if completed, !movie.isWatched {
            movie.isWatched = true
            completion = Completion(ref: ref)
        }

        try context.save()
        return completion
    }

    private func writeEpisode(
        id: String,
        progress: TimeInterval,
        completed: Bool,
        ref: PlayableMedia.ContentRef
    ) throws -> Completion? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let episode = try context.fetch(descriptor).first else { return nil }

        episode.watchProgress = progress
        episode.lastWatchedDate = Date()
        if let series = episode.series {
            series.lastWatchedDate = Date()
        }

        var completion: Completion?
        if completed, !episode.isWatched {
            episode.isWatched = true
            completion = Completion(ref: ref)
        }

        try context.save()
        return completion
    }

    private func touchLive(id: String) throws {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let stream = try context.fetch(descriptor).first else { return }
        stream.lastWatchedDate = Date()
        try context.save()
    }
}
