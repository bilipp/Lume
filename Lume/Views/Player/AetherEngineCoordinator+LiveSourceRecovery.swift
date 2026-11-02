//
//  AetherEngineCoordinator+LiveSourceRecovery.swift
//  Lume
//
//  A live source that stays down past the engine's own bounded reopen makes
//  the engine park production and publish `liveSourceReset`. Retuning (a
//  fresh load) throws away the cache, the replay history and the picture on
//  screen, and costs a full join. The engine can often pick the parked source
//  up again in place (`retryLiveSourceRecovery`), keeping all of that, but it
//  never schedules that retry itself: the timing is Lume's. So a reset first
//  waits a short backoff and asks for an in-place retry; only when the engine
//  can't continue the source this way, the budget runs out, or the picture
//  still hasn't moved a while after an accepted retry, does it retune.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge
    import OSLog

    extension AetherEngineCoordinator {
        /// How long an accepted in-place retry may take to get the picture
        /// moving again before the channel is retuned.
        nonisolated static let liveSourceRecoveryCheckWindow: Duration = .seconds(20)
        /// Extra time, granted once, when the window runs out while the engine
        /// is refilling: the source came back late in the window and the
        /// picture is about to move. A stall or a stuck `.playing` gets none.
        nonisolated static let liveSourceRecoveryRefillGrace: Duration = .seconds(10)
        /// How far the playhead must advance within that window to count as
        /// recovered; a frozen consumer reports `.playing` with a stuck clock.
        nonisolated static let liveSourceRecoveryMinimumProgress: Double = 2

        func liveSourceDidReset() {
            guard currentMedia?.isLive == true, hasStartedPlayback, !reportedFailure else {
                Logger.player.warning("AetherEngine live source reset → retune")
                streamFailed(.sourceEnded)
                return
            }
            // A retry already queued or under way absorbs further resets.
            if liveSourceRecovery != nil, !liveSourceRecoveryIsChecking {
                return
            }
            liveSourceRecovery?.cancel()
            guard let backoff = liveSourceRecoveryBudget.admit(at: .now) else {
                Logger.player.warning("AetherEngine live source reset: in-place retries spent → retune")
                streamFailed(.sourceEnded)
                return
            }
            let attempt = liveSourceRecoveryBudget.attempts
            Logger.player.warning("AetherEngine live source reset → in-place retry \(attempt) after \(backoff.components.seconds) s")
            liveSourceRecoveryIsChecking = false
            liveSourceRecovery = Task { [weak self] in
                try? await Task.sleep(for: backoff)
                guard let self, !Task.isCancelled else { return }
                await retryLiveSource()
            }
        }

        private func retryLiveSource() async {
            guard let session, !reportedFailure else {
                liveSourceRecovery = nil
                return
            }
            guard session.retryLiveSourceRecovery() else {
                liveSourceRecovery = nil
                Logger.player.warning("AetherEngine can't resume the live source in place → retune")
                streamFailed(.sourceEnded)
                return
            }
            liveSourceRecoveryIsChecking = true
            let positionAtRetry = session.currentTime
            try? await Task.sleep(for: Self.liveSourceRecoveryCheckWindow)
            guard !Task.isCancelled, !reportedFailure else { return }
            var verdict = currentLiveSourceRecoveryVerdict(since: positionAtRetry)
            if verdict == .refilling {
                Logger.player.info("AetherEngine live source refilling after an in-place retry → waiting a little longer")
                try? await Task.sleep(for: Self.liveSourceRecoveryRefillGrace)
                guard !Task.isCancelled, !reportedFailure else { return }
                verdict = currentLiveSourceRecoveryVerdict(since: positionAtRetry)
            }
            liveSourceRecovery = nil
            liveSourceRecoveryIsChecking = false
            if verdict == .recovered {
                Logger.player.info("AetherEngine live source resumed in place")
            } else {
                Logger.player.error("AetherEngine live picture still frozen after an in-place retry → retune")
                streamFailed(.sourceEnded)
            }
        }

        private func currentLiveSourceRecoveryVerdict(since positionAtRetry: Double) -> LiveSourceRecoveryVerdict {
            Self.liveSourceRecoveryVerdict(
                phase: lastPhase,
                positionAtRetry: positionAtRetry,
                positionNow: session?.currentTime ?? positionAtRetry
            )
        }

        /// Recovered: playing, and the playhead moved since the retry.
        /// Refilling: the source is back and the engine is buffering towards
        /// the picture. Anything else (still stalled, or `.playing` with a
        /// stuck clock) is frozen.
        nonisolated static func liveSourceRecoveryVerdict(
            phase: LumeAetherPhase,
            positionAtRetry: Double,
            positionNow: Double
        ) -> LiveSourceRecoveryVerdict {
            switch phase {
            case .playing where positionNow - positionAtRetry >= liveSourceRecoveryMinimumProgress:
                .recovered
            case .rebuffering, .loading, .seeking:
                .refilling
            default:
                .frozen
            }
        }

        func cancelLiveSourceRecovery() {
            liveSourceRecovery?.cancel()
            liveSourceRecovery = nil
            liveSourceRecoveryIsChecking = false
            liveSourceRecoveryBudget.reset()
        }
    }

    nonisolated enum LiveSourceRecoveryVerdict: Equatable {
        case recovered
        case refilling
        case frozen
    }

    /// Bounds the in-place retries of one load. Resets that follow each other
    /// within `window` of the last retry count against `maxAttempts`; a source
    /// that then stays healthy for longer than the window starts afresh. Each
    /// retry waits a little longer than the last.
    nonisolated struct LiveSourceRecoveryBudget: Equatable {
        static let maxAttempts = 3
        static let window: Duration = .seconds(60)

        private(set) var attempts = 0
        private var lastAttempt: ContinuousClock.Instant?

        /// Admits another retry at `now`, returning the backoff before it, or
        /// nil when the budget is spent and the channel has to be retuned.
        mutating func admit(at now: ContinuousClock.Instant) -> Duration? {
            if let lastAttempt, now - lastAttempt > Self.window {
                attempts = 0
            }
            guard attempts < Self.maxAttempts else { return nil }
            attempts += 1
            lastAttempt = now
            return Self.backoff(forAttempt: attempts)
        }

        mutating func reset() {
            attempts = 0
            lastAttempt = nil
        }

        /// 1 s, 2 s, 4 s.
        static func backoff(forAttempt attempt: Int) -> Duration {
            .seconds(1 << max(0, attempt - 1))
        }
    }

#endif
