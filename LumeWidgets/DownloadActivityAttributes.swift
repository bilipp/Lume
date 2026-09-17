#if os(iOS)
    import ActivityKit
    import Foundation

    /// Shared between the app (which starts/updates the activity) and the
    /// LumeWidgets extension (which renders it). One activity spans a whole
    /// download batch rather than one per file: `DownloadManager` runs a queue,
    /// so items keep starting and finishing while the user is away, and a
    /// per-file activity would stack up banners nobody asked for.
    ///
    /// Everything that changes as the queue drains lives in the content state,
    /// summarised down to what fits a glance: the download closest to finishing
    /// plus how much is behind it.
    nonisolated struct DownloadActivityAttributes: ActivityAttributes {
        nonisolated struct ContentState: Codable, Hashable {
            /// Title of the download the activity is fronting — the one closest
            /// to finishing, so the visible progress bar is the one about to pay off.
            var title: String
            var fractionCompleted: Double
            /// "3.2 MB/s · 2 min", or nil while the speed is still being measured.
            var statsLine: String?
            /// Transfers currently running, this one included.
            var activeCount: Int
            /// Items waiting for a free slot (see `downloads.maxConcurrent`).
            var queuedCount: Int
            /// Tallies for the batch, used for the closing summary.
            var completedCount: Int
            var failedCount: Int
            /// Terminal state: the queue drained. Only ever set on the final
            /// content pushed as the activity ends.
            var isFinished: Bool

            /// Items the batch still owes the user, fronted item included.
            var remainingCount: Int {
                activeCount + queuedCount
            }
        }

        /// One activity per download batch; the id only disambiguates requests.
        var sessionID: String
    }
#endif
