import Foundation

/// Controls how often the background new-episode scan runs. Persists the last
/// run timestamp in UserDefaults so the once-per-day gate survives app restarts.
enum NewEpisodeScanScheduler {
    static let storageKey = "lume.newEpisodesScanDate"
    static let scanInterval: TimeInterval = 24 * 60 * 60

    /// Whether enough time has passed since the last scan to run again.
    static func isDue(now: Date = Date()) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: storageKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(last) >= scanInterval
    }

    /// Records the current time as the last-completed scan date.
    static func markComplete(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: storageKey)
    }
}
