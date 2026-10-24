//
//  FullScreenPlayerView+Trackers.swift
//  Lume
//
//  The player's progress writes and its one-time "watched" push to Trakt and
//  Simkl, split out of `FullScreenPlayerView` to keep that file inside the
//  600-line cap.
//

import SwiftUI

extension FullScreenPlayerView {
    func syncWatchedServices(ref: PlayableMedia.ContentRef) {
        WatchedServicesSync.sync(ref: ref, in: modelContext)
    }

    /// Writes progress after any write already in flight, and runs the
    /// trackers' watched sync when this write is the one that finished the item.
    func enqueueProgressWrite(
        ref: PlayableMedia.ContentRef,
        progress: TimeInterval,
        duration: TimeInterval,
        force: Bool,
        holdLive: Bool = false
    ) {
        guard let writer = progressWriter else { return }
        // Held so `endReviewSession` can await it: `writer` is an actor, so the
        // write suspends, and without the handle the review policy would
        // read `completedTitles` before this task increments it — the third
        // finished title would then only arm the *next* session.
        let write = WatchProgressWriter.Write(
            ref: ref, progress: progress, duration: duration, force: force, holdLive: holdLive
        )
        pendingProgressWrite = WatchProgressWriter.enqueue(
            write, on: writer, after: pendingProgressWrite
        ) { ref in
            syncWatchedServices(ref: ref)
            AppStoreReviewPrompt.shared.noteCompletedTitle()
        }
    }
}
