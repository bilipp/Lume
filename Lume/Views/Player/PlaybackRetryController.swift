import Foundation
import OSLog

/// Bounded, exponential-backoff reconnect coordinator shared by the player
/// engines.
///
/// When a stream drops mid-playback (a temporary connection loss) the engine
/// reports a terminal state — VLCKit's `.error`/`.stopped`, KSPlayer's
/// `.error` — and otherwise sits frozen with no recovery. The engine hands
/// that event here; this controller re-invokes the supplied `reload` closure
/// on a backoff schedule until playback resumes or the attempt budget is
/// spent, after which it gives up so a genuinely dead stream doesn't spin
/// forever.
///
/// Publishes nothing — retries are deliberately silent — so engines hold it as
/// a plain reference (`@State` in SwiftUI, a stored property in the VLC
/// coordinator).
@MainActor
final class PlaybackRetryController {
    /// Delay before each successive attempt, in seconds. The element count is
    /// the attempt budget (6 reconnects spanning ~31s before giving up).
    private static let backoff: [TimeInterval] = [1, 2, 4, 8, 8, 8]

    private var attempt = 0
    private var pending: Task<Void, Never>?
    private var gaveUp = false

    /// Whether the budget is exhausted and no further retries will be made.
    var hasGivenUp: Bool {
        gaveUp
    }

    /// Mark playback healthy again (the player reached a playing state). Clears
    /// the attempt counter and the give-up flag so a later, unrelated drop gets
    /// a full budget.
    func reset() {
        attempt = 0
        gaveUp = false
        pending?.cancel()
        pending = nil
    }

    /// Cancel any scheduled retry without touching the budget — used on
    /// teardown, where we're going away regardless.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Schedule the next reconnect if the budget allows. A no-op while a retry
    /// is already pending, so the burst of repeated terminal-state callbacks a
    /// single outage produces collapses into one scheduled attempt.
    func scheduleRetry(_ reload: @escaping () -> Void) {
        guard pending == nil, !gaveUp else { return }
        guard attempt < Self.backoff.count else {
            gaveUp = true
            let spent = attempt
            Logger.player.error("reconnect: giving up after \(spent, privacy: .public) attempts")
            return
        }

        let delay = Self.backoff[attempt]
        let number = attempt + 1
        let total = Self.backoff.count
        attempt += 1
        Logger.player.log("reconnect: attempt \(number, privacy: .public)/\(total, privacy: .public) in \(delay, format: .fixed(precision: 0), privacy: .public)s")

        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Clear before reloading so the terminal state of a *failed* retry
            // can schedule the next attempt.
            pending = nil
            reload()
        }
    }
}
