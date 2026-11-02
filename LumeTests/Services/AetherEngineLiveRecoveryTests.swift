#if !os(visionOS)
    @testable import Lume
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
#endif
