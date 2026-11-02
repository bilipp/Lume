//
//  AetherEngineCoordinator+LiveRecovery.swift
//  Lume
//
//  A live channel whose source goes quiet longer than the buffer lasts runs
//  AVPlayer dry, and AVPlayer then pauses itself. The engine takes a stable
//  pause for an outside command (AVKit, Now Playing) and reports `.paused`,
//  so without this the player sat on a frozen picture showing its paused
//  state, with nothing asking for the channel back. A pause the viewer did
//  not ask for is a stall: show it as buffering, ask the engine to play
//  again, and hand the channel to the reconnect path if it stays down.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge
    import OSLog

    extension AetherEngineCoordinator {
        /// How often play is asked for again while the engine stays paused.
        static let unrequestedPauseReassertInterval: Duration = .seconds(3)
        /// How long a live channel may stay paused on its own before it is
        /// reported as stalled, so the reconnect path retunes it. The engine
        /// gives up on a quiet source by itself well within this; this only
        /// bounds a session that neither recovers nor gives up.
        static let unrequestedPauseWindow: Duration = .seconds(20)

        /// The engine paused a live channel that was playing, and neither the
        /// viewer nor a Picture in Picture window asked for it.
        var isUnrequestedLivePause: Bool {
            Self.isUnrequestedLivePause(
                isLive: currentMedia?.isLive == true,
                hasStartedPlayback: hasStartedPlayback,
                isPauseRequested: isPauseRequested,
                isPipActive: isPipActive,
                hasReportedFailure: reportedFailure
            )
        }

        /// A pause is the engine's own when the channel is live and was
        /// playing, nobody asked for it, and no Picture in Picture window
        /// (whose own controls pause the player directly) is up. A load that
        /// already failed belongs to the reconnect path.
        nonisolated static func isUnrequestedLivePause(
            isLive: Bool,
            hasStartedPlayback: Bool,
            isPauseRequested: Bool,
            isPipActive: Bool,
            hasReportedFailure: Bool
        ) -> Bool {
            isLive && hasStartedPlayback && !isPauseRequested && !isPipActive && !hasReportedFailure
        }

        func recoverUnrequestedPause() {
            isBuffering = true
            guard unrequestedPauseRecovery == nil else { return }
            Logger.player.warning("AetherEngine paused the live channel by itself (buffer ran dry) → resuming")
            PlaybackQoE.shared.noteStallBegan()
            session?.play()
            unrequestedPauseRecovery = Task { [weak self] in
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: Self.unrequestedPauseWindow)
                while clock.now < deadline {
                    try? await Task.sleep(for: Self.unrequestedPauseReassertInterval)
                    guard let self, !Task.isCancelled else { return }
                    guard lastPhase == .paused else { continue }
                    session?.play()
                }
                guard let self, !Task.isCancelled else { return }
                unrequestedPauseRecovery = nil
                Logger.player.error("AetherEngine live channel stayed paused on its own → reconnect")
                streamFailed(.interrupted)
            }
        }

        func cancelUnrequestedPauseRecovery() {
            unrequestedPauseRecovery?.cancel()
            unrequestedPauseRecovery = nil
        }
    }

#endif
