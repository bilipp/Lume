//
//  DownloadManager+LiveActivity.swift
//  Lume
//
//  Bridges the download queue to its Live Activity. Kept apart from
//  `DownloadManager` so the queue itself stays free of ActivityKit and the
//  platform gating lives in one place — Live Activities are iOS-only, while
//  downloads also ship on macOS.
//

import Foundation

extension DownloadManager {
    /// Pushes the current queue into the Live Activity.
    ///
    /// - Parameters:
    ///   - force: bypass the controller's tick throttle, for a structural
    ///     change (an item starting, finishing or failing) rather than another
    ///     progress tick.
    ///   - endsWhenIdle: whether an empty queue should end the activity. Pass
    ///     false while the background session still has completion events to
    ///     deliver, so the closing summary counts them.
    func refreshLiveActivity(force: Bool = false, endsWhenIdle: Bool = true) {
        #if os(iOS)
            // Closest to finishing first: that's the download the activity
            // fronts, so the visible bar is the one about to pay off. Ties break
            // on id purely to keep the choice stable between ticks — the
            // dictionary's own order is not.
            let active = activeDownloads.values.sorted {
                $0.fractionCompleted == $1.fractionCompleted
                    ? $0.id < $1.id
                    : $0.fractionCompleted > $1.fractionCompleted
            }
            DownloadActivityController.shared.refresh(
                active: active,
                queuedCount: pendingIDs.count,
                force: force,
                endsWhenIdle: endsWhenIdle
            )
        #endif
    }

    func noteLiveActivityCompleted() {
        #if os(iOS)
            DownloadActivityController.shared.noteCompleted()
        #endif
    }

    func noteLiveActivityFailed() {
        #if os(iOS)
            DownloadActivityController.shared.noteFailed()
        #endif
    }
}
