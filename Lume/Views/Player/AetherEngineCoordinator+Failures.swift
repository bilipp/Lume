//
//  AetherEngineCoordinator+Failures.swift
//  Lume
//
//  Where a failed AetherEngine load is routed, and the startup watchdog.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge
    import OSLog

    extension AetherEngineCoordinator {
        /// A failure the engine reported, or a load that threw. `nil` is a
        /// throw the bridge could not classify.
        func engineFailed(_ failure: LumeAetherFailure?) {
            let kind = failure?.kind ?? ""
            let code = failure?.underlyingCode.map(String.init) ?? "-"
            let message = LogRedaction.scrubURLs(in: failure?.message ?? "")
            Logger.player.error("AetherEngine error \(kind, privacy: .public) (\(code, privacy: .public)): \(message, privacy: .public)")
            streamFailed(AetherEngineFailure.classify(kind: kind, code: failure?.underlyingCode))
        }

        /// The load is finished: it failed, or never started within the
        /// startup window. Reported once per load. A stream that has played
        /// goes to the reconnect path (`onStalled`); anything else stops the
        /// engine before the host moves on to the next engine.
        func streamFailed(_ failure: AetherEngineFailure) {
            guard !reportedFailure else { return }
            reportedFailure = true
            startupTask?.cancel()
            // Local copies: os_log interpolation is an autoclosure; swiftformat strips `self.`
            let started = hasStartedPlayback
            let played = hasPlayedStream
            let cause = failure.rawValue
            if failure == .sourceEnded {
                Logger.player.info("AetherEngine live source ended (hasStartedPlayback: \(started), hasPlayedStream: \(played))")
            } else {
                Logger.player.error("AetherEngine failed: \(cause, privacy: .public) (hasStartedPlayback: \(started), hasPlayedStream: \(played))")
            }
            if started || played {
                onStalled?(failure)
            } else {
                PlaybackQoE.shared.noteStartupFailure()
                session?.stop()
                onPlaybackFailure?(failure)
            }
        }

        /// Startup failure watchdog. The window rolls while the engine
        /// demonstrably works through its startup checkpoints (a slow origin
        /// can spend most of it in stream analysis); a load stuck on one
        /// checkpoint still fails within `timeout`, and a hard cap bounds the
        /// rest.
        func makeStartupWatchdog(timeout: TimeInterval) -> Task<Void, Never> {
            StartupWatchdog.start(
                timeout: timeout,
                pollInterval: .seconds(1),
                progress: { Int64(self.session?.startupCheckpointsCompleted ?? 0) },
                hasStarted: { self.hasStartedPlayback },
                onTimeout: { lastCheckpoint in
                    Logger.player.error("AetherEngine startup window elapsed (checkpoint \(lastCheckpoint), never played)")
                    self.streamFailed(.interrupted)
                }
            )
        }
    }

#endif
