import Foundation
@testable import Lume
import Testing

// MARK: - Session health

/// The gate that decides whether the policy above is ever consulted. Pure, so
/// it needs no player, no engine and no simulator — only two snapshots.
final class PlaybackSessionHealthTests {
    /// Comfortably past `minimumWatchedSeconds`, so these cases turn on the
    /// fault being measured rather than on the short-session exclusion.
    private let watched = PlaybackSessionHealth.minimumWatchedSeconds * 10

    private func snapshot(
        engineFallbacks: Int = 0,
        startupFailures: Int = 0,
        rebufferSeconds: TimeInterval = 0,
        watchedSeconds: TimeInterval = 0
    ) -> PlaybackHealthSnapshot {
        var snapshot = PlaybackHealthSnapshot()
        snapshot.engineFallbacks = engineFallbacks
        snapshot.startupFailures = startupFailures
        snapshot.rebufferSeconds = rebufferSeconds
        snapshot.watchedSeconds = watchedSeconds
        return snapshot
    }

    @Test func `a clean session of decent length is healthy`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(watchedSeconds: watched)
        )
        #expect(verdict == .healthy)
    }

    /// The whole reason the tracker diffs instead of reading the summary: a
    /// user with a lifetime of faults behind them can still have a clean
    /// session, and must still be askable.
    @Test func `faults already on the clock do not taint a clean session`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(engineFallbacks: 12, startupFailures: 30, rebufferSeconds: 900),
            to: snapshot(
                engineFallbacks: 12,
                startupFailures: 30,
                rebufferSeconds: 900,
                watchedSeconds: watched
            )
        )
        #expect(verdict == .healthy)
    }

    @Test func `an engine fallback during the session is unhealthy`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(engineFallbacks: 1),
            to: snapshot(engineFallbacks: 2, watchedSeconds: watched)
        )
        #expect(verdict == .unhealthy(.engineFallback))
    }

    @Test func `a startup failure during the session is unhealthy`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(startupFailures: 4),
            to: snapshot(startupFailures: 5, watchedSeconds: watched)
        )
        #expect(verdict == .unhealthy(.startupFailure))
    }

    @Test func `rebuffering past the ceiling is unhealthy`() {
        let stalled = watched * (PlaybackSessionHealth.rebufferRatioCeiling + 0.01)
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(rebufferSeconds: stalled, watchedSeconds: watched)
        )
        #expect(verdict == .unhealthy(.rebuffering))
    }

    @Test func `rebuffering under the ceiling is still healthy`() {
        let stalled = watched * (PlaybackSessionHealth.rebufferRatioCeiling - 0.01)
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(rebufferSeconds: stalled, watchedSeconds: watched)
        )
        #expect(verdict == .healthy)
    }

    /// A session too short to judge is deliberately *not* healthy: a diff of
    /// zeros would otherwise read as flawless and arm a prompt off a viewer who
    /// opened a channel and immediately left.
    @Test func `a session below the watch floor is not measured`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(watchedSeconds: PlaybackSessionHealth.minimumWatchedSeconds - 1)
        )
        #expect(verdict == .notMeasured(.tooShort))
        #expect(verdict.isHealthy == false)
    }

    @Test func `only the healthy verdict may arm a prompt`() {
        #expect(PlaybackSessionHealth.healthy.isHealthy)
        #expect(PlaybackSessionHealth.unhealthy(.rebuffering).isHealthy == false)
        #expect(PlaybackSessionHealth.notMeasured(.suspended).isHealthy == false)
    }
}

// MARK: - Session brackets

/// The tracker's bookkeeping, not the verdict maths. Two players can be open at
/// once — macOS gives the player its own window, iPadOS its own scene — and a
/// single-slot tracker let the second one clobber the first one's baseline, so
/// the first was judged against the wrong snapshot and the second inherited a
/// verdict it had not earned.
@MainActor
final class PlaybackHealthTrackerTests {
    /// QoE is a shared singleton, so every test releases the suspension it
    /// took under its own owner token — inside the test body, never in
    /// `deinit`, which is nonisolated and cannot touch main-actor state.
    /// Nothing here calls `reset()`, which would persist to the standard
    /// defaults suite.
    private let owner = "PlaybackHealthTrackerTests-\(UUID().uuidString)"

    @Test func `concurrent sessions get their own brackets`() {
        let first = PlaybackHealthTracker.shared.beginSession()
        let second = PlaybackHealthTracker.shared.beginSession()
        #expect(first != second)

        // Closing the second must leave the first's bracket open, which is
        // exactly what a single slot could not do.
        #expect(PlaybackHealthTracker.shared.endSession(second) != nil)
        #expect(PlaybackHealthTracker.shared.endSession(first) != nil)
    }

    @Test func `a closed session cannot be closed twice`() {
        let token = PlaybackHealthTracker.shared.beginSession()
        #expect(PlaybackHealthTracker.shared.endSession(token) != nil)
        // No stale verdict to inherit: the bracket is gone, not merely stale.
        #expect(PlaybackHealthTracker.shared.endSession(token) == nil)
    }

    @Test func `a session that began while QoE was suspended is not measured`() {
        PlaybackQoE.shared.suspend(for: owner)
        let token = PlaybackHealthTracker.shared.beginSession()
        PlaybackQoE.shared.resume(for: owner)
        #expect(PlaybackHealthTracker.shared.endSession(token) == .notMeasured(.suspended))
    }

    @Test func `a suspended session stays unmeasured even if it began clear`() {
        let token = PlaybackHealthTracker.shared.beginSession()
        PlaybackQoE.shared.suspend(for: owner)
        defer { PlaybackQoE.shared.resume(for: owner) }
        #expect(PlaybackHealthTracker.shared.endSession(token) == .notMeasured(.suspended))
    }

    /// A cast suspends QoE mid-session and resumes it when it stops, so the
    /// session must stay unmeasured after the suspension is gone.
    @Test func `a suspension that came and went still voids every open session`() {
        let first = PlaybackHealthTracker.shared.beginSession()
        let second = PlaybackHealthTracker.shared.beginSession()
        PlaybackQoE.shared.suspend(for: owner, handingOff: true)
        PlaybackQoE.shared.resume(for: owner)
        #expect(PlaybackHealthTracker.shared.endSession(first) == .notMeasured(.suspended))
        #expect(PlaybackHealthTracker.shared.endSession(second) == .notMeasured(.suspended))
    }

    @Test func `a session after a suspension ended is judged normally`() {
        PlaybackQoE.shared.suspend(for: owner)
        PlaybackQoE.shared.resume(for: owner)
        let token = PlaybackHealthTracker.shared.beginSession()
        #expect(PlaybackHealthTracker.shared.endSession(token) != .notMeasured(.suspended))
    }
}
