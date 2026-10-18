import Foundation
import SwiftData

/// Writes watch progress for a cast that ended with no full-screen player
/// open — the viewer closed it and the receiver played on. While a player is
/// open it commits its casts itself; `CastService` routes an end here only
/// when none is attached, so a cast is never committed twice.
@MainActor
final class CastProgressCommitter {
    /// The last commit, for tests to await.
    private(set) var pendingCommit: Task<Void, Never>?

    private let container: ModelContainer
    private let syncWatched: (PlayableMedia.ContentRef) -> Void
    private let noteCompletedTitle: () -> Void
    private lazy var writer = WatchProgressWriter(container: container)

    /// `container` is the catalog container — watch progress lives on the
    /// catalog models, never in the CloudKit mirror.
    convenience init(container: ModelContainer) {
        self.init(
            container: container,
            syncWatched: { WatchedServicesSync.sync(ref: $0, in: container.mainContext) },
            noteCompletedTitle: { AppStoreReviewPrompt.shared.noteCompletedTitle() }
        )
    }

    init(
        container: ModelContainer,
        syncWatched: @escaping (PlayableMedia.ContentRef) -> Void,
        noteCompletedTitle: @escaping () -> Void
    ) {
        self.container = container
        self.syncWatched = syncWatched
        self.noteCompletedTitle = noteCompletedTitle
    }

    /// Writes `commit` after any earlier one, and runs the trackers' watched
    /// sync when this write is the one that finished the item.
    func commit(_ commit: CastProgressCommit) {
        let syncWatched = syncWatched
        let noteCompletedTitle = noteCompletedTitle
        let write = WatchProgressWriter.Write(
            ref: commit.ref, progress: commit.position, duration: commit.duration, force: true
        )
        pendingCommit = WatchProgressWriter.enqueue(
            write, on: writer, after: pendingCommit
        ) { ref in
            syncWatched(ref)
            noteCompletedTitle()
        }
    }
}

nonisolated extension PlayerCastPolicy {
    /// The progress a cast that ended with no player attached leaves to write.
    /// `nil` when a player commits it itself, when Lume didn't load the item
    /// (a session resumed at launch), and for live channels — their "recently
    /// watched" touch was written when the player closed, and a receiver
    /// position means nothing for them.
    static func headlessCommit(for end: CastSessionEnd, hostAttached: Bool) -> CastProgressCommit? {
        guard !hostAttached, let request = end.request, request.streamType == .buffered else { return nil }
        switch request.contentRef {
        case .movie, .episode:
            return progress(
                ref: request.contentRef,
                isLive: false,
                position: end.reason == .finished ? end.duration ?? end.lastPosition : end.lastPosition,
                duration: end.duration
            )
        case .live, .recording:
            return nil
        }
    }
}
