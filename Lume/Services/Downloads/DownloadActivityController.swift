//
//  DownloadActivityController.swift
//  Lume
//
//  Drives the lock-screen / Dynamic Island Live Activity for the background
//  download queue (iOS only). `DownloadManager` owns the lifecycle: one
//  activity per batch, requested when the first transfer starts, updated in
//  place as items progress and the queue drains, ended with a summary once
//  nothing is left.
//

#if os(iOS)
    import ActivityKit
    import OSLog
    import UIKit

    @MainActor
    final class DownloadActivityController {
        static let shared = DownloadActivityController()

        private var activity: Activity<DownloadActivityAttributes>?
        private var lastPush = Date.distantPast

        /// Tallies for the current batch, cleared when the activity ends. Kept
        /// here rather than on `DownloadManager` so the whole notion of a
        /// "batch" lives with the thing that renders it, and in `UserDefaults`
        /// rather than in memory because a batch routinely outlives the process:
        /// the system terminates a backgrounded app and relaunches it to deliver
        /// each completion, so in-memory counters would reset under exactly the
        /// scenario this activity exists for and the closing summary would
        /// report "Download Complete" for a batch of six.
        private static let completedKey = "downloads.activity.completedCount"
        private static let failedKey = "downloads.activity.failedCount"

        private var completedCount: Int {
            get { UserDefaults.standard.integer(forKey: Self.completedKey) }
            set { UserDefaults.standard.set(newValue, forKey: Self.completedKey) }
        }

        private var failedCount: Int {
            get { UserDefaults.standard.integer(forKey: Self.failedKey) }
            set { UserDefaults.standard.set(newValue, forKey: Self.failedKey) }
        }

        /// Progress arrives ~4×/s per transfer. ActivityKit budgets updates and
        /// starts dropping them when an app pushes too eagerly, so ticks are
        /// spaced out to roughly one a second; structural changes (an item
        /// starting, finishing, failing) push immediately regardless.
        private static let minimumTickInterval: TimeInterval = 1

        private init() {}

        func noteCompleted() {
            completedCount += 1
        }

        func noteFailed() {
            failedCount += 1
        }

        /// Reflects the queue into the activity: request it on the first call,
        /// update it in place afterwards, end it once nothing is left.
        ///
        /// - Parameters:
        ///   - active: running transfers, closest-to-finishing first.
        ///   - queuedCount: items waiting for a free slot.
        ///   - force: bypass the tick throttle for a structural change.
        ///   - endsWhenIdle: whether an empty queue should end the activity.
        ///     False while completion events are still being delivered, whose
        ///     tallies the closing summary is owed.
        func refresh(active: [ActiveDownload], queuedCount: Int, force: Bool, endsWhenIdle: Bool) {
            guard let front = active.first else {
                if endsWhenIdle { finish() }
                return
            }
            let now = Date.now
            guard force || now.timeIntervalSince(lastPush) >= Self.minimumTickInterval else { return }
            lastPush = now

            let state = DownloadActivityAttributes.ContentState(
                title: front.title,
                fractionCompleted: front.fractionCompleted,
                statsLine: front.statsLine,
                activeCount: active.count,
                queuedCount: queuedCount,
                completedCount: completedCount,
                failedCount: failedCount,
                isFinished: false
            )
            // A stalled transfer shouldn't leave a bar frozen at 40% forever;
            // past the stale date the system dims the activity instead.
            let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(10 * 60))

            if let activity = adoptedActivity() {
                Task { await activity.update(content) }
                return
            }
            // `Activity.request` only succeeds from the foreground. Downloads
            // are started by a tap, so the first refresh lands there; a launch
            // purely to deliver background session events must not try.
            guard ActivityAuthorizationInfo().areActivitiesEnabled,
                  UIApplication.shared.applicationState != .background
            else { return }
            do {
                activity = try Activity.request(
                    attributes: DownloadActivityAttributes(sessionID: UUID().uuidString),
                    content: content
                )
            } catch {
                Logger.downloads.error("Download Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Ends the activity with a summary of how the batch went, and lingers
        /// briefly so someone who only glances at the lock screen still sees the
        /// outcome. A batch that produced nothing (everything cancelled) just
        /// disappears.
        private func finish() {
            defer {
                UserDefaults.standard.removeObject(forKey: Self.completedKey)
                UserDefaults.standard.removeObject(forKey: Self.failedKey)
                lastPush = .distantPast
            }
            guard let activity = adoptedActivity() else { return }
            self.activity = nil
            guard completedCount + failedCount > 0 else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                return
            }
            let state = DownloadActivityAttributes.ContentState(
                title: "",
                fractionCompleted: 1,
                statsLine: nil,
                activeCount: 0,
                queuedCount: 0,
                completedCount: completedCount,
                failedCount: failedCount,
                isFinished: true
            )
            let content = ActivityContent(state: state, staleDate: nil)
            Task {
                await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15)))
            }
        }

        /// The live activity, re-adopting one that outlived the app process.
        ///
        /// A background session keeps transferring while Lume is suspended or
        /// terminated, and the app can be relaunched in the background purely to
        /// receive a completion event — at which point this controller is fresh
        /// but the activity from before is still on the lock screen. Updating it
        /// (unlike requesting one) is allowed from the background, so picking it
        /// back up is what keeps the banner from freezing mid-progress.
        private func adoptedActivity() -> Activity<DownloadActivityAttributes>? {
            if let activity {
                return activity
            }
            guard let existing = Activity<DownloadActivityAttributes>.activities.first else { return nil }
            activity = existing
            return existing
        }
    }
#endif
