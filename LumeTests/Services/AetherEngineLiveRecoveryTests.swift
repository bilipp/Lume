#if !os(visionOS)
    @testable import Lume
    import LumeAetherBridge
    import Testing

    struct AetherEngineLiveRecoveryTests {
        private func isUnrequested(
            isLive: Bool = true,
            hasStartedPlayback: Bool = true,
            isPauseRequested: Bool = false,
            isPipActive: Bool = false,
            hasReportedFailure: Bool = false
        ) -> Bool {
            AetherEngineCoordinator.isUnrequestedLivePause(
                isLive: isLive,
                hasStartedPlayback: hasStartedPlayback,
                isPauseRequested: isPauseRequested,
                isPipActive: isPipActive,
                hasReportedFailure: hasReportedFailure
            )
        }

        @Test func `a live channel the engine paused on its own is a stall`() {
            #expect(isUnrequested())
        }

        @Test func `a pause the viewer asked for stays a pause`() {
            #expect(!isUnrequested(isPauseRequested: true))
        }

        @Test func `video on demand keeps the engine's pause`() {
            #expect(!isUnrequested(isLive: false))
        }

        @Test func `a pause before the first frame is part of the startup`() {
            #expect(!isUnrequested(hasStartedPlayback: false))
        }

        @Test func `picture in picture owns its own pause`() {
            #expect(!isUnrequested(isPipActive: true))
        }

        @Test func `a load already reported as failed is left to the reconnect path`() {
            #expect(!isUnrequested(hasReportedFailure: true))
        }
    }

    struct AetherEngineLiveSourceRecoveryTests {
        private let start = ContinuousClock.Instant.now

        @Test func `retries back off and run out after three`() {
            var budget = LiveSourceRecoveryBudget()
            #expect(budget.admit(at: start) == .seconds(1))
            #expect(budget.admit(at: start + .seconds(10)) == .seconds(2))
            #expect(budget.admit(at: start + .seconds(20)) == .seconds(4))
            #expect(budget.admit(at: start + .seconds(30)) == nil)
            #expect(budget.attempts == 3)
        }

        @Test func `a source that stays up longer than the window starts afresh`() {
            var budget = LiveSourceRecoveryBudget()
            _ = budget.admit(at: start)
            _ = budget.admit(at: start + .seconds(10))
            _ = budget.admit(at: start + .seconds(20))
            #expect(budget.admit(at: start + .seconds(81)) == .seconds(1))
            #expect(budget.attempts == 1)
        }

        @Test func `a reset within the window of the last retry still counts`() {
            var budget = LiveSourceRecoveryBudget()
            _ = budget.admit(at: start)
            _ = budget.admit(at: start + .seconds(55))
            _ = budget.admit(at: start + .seconds(110))
            #expect(budget.admit(at: start + .seconds(165)) == nil)
        }

        @Test func `reset clears the budget`() {
            var budget = LiveSourceRecoveryBudget()
            for offset in 0 ..< 3 {
                _ = budget.admit(at: start + .seconds(offset))
            }
            budget.reset()
            #expect(budget == LiveSourceRecoveryBudget())
            #expect(budget.admit(at: start + .seconds(4)) == .seconds(1))
        }

        private func verdict(_ phase: LumeAetherPhase, moved: Double) -> LiveSourceRecoveryVerdict {
            AetherEngineCoordinator.liveSourceRecoveryVerdict(phase: phase, positionAtRetry: 100, positionNow: 100 + moved)
        }

        @Test func `recovery needs a moving picture, not just the playing phase`() {
            #expect(verdict(.playing, moved: 15) == .recovered)
            #expect(verdict(.playing, moved: 0.5) == .frozen)
            #expect(verdict(.paused, moved: 15) == .frozen)
        }

        @Test func `a source still down is frozen, one that came back is refilling`() {
            #expect(verdict(.stalled(reconnecting: true), moved: 0) == .frozen)
            #expect(verdict(.stalled(reconnecting: false), moved: 0) == .frozen)
            #expect(verdict(.rebuffering, moved: 0) == .refilling)
            #expect(verdict(.loading, moved: 0) == .refilling)
        }
    }
#endif
