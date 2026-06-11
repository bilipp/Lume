import KSPlayer
import OSLog
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    // MARK: - Loading state

    /// Drive the loading indicator + initial controls gate off KSPlayer's state.
    /// `.bufferFinished` is the first frame actually playing, so it both clears
    /// the spinner and unlocks the controls for good; a later `.buffering` (a
    /// mid-stream stall) re-shows the spinner without re-hiding the controls.
    ///
    /// This raises the spinner reliably but can't be trusted to lower it: after
    /// the first `.bufferFinished`, KSPlayer may re-emit a non-playing state
    /// (`.readyToPlay` on a second-open, a track/subtitle attach) and never emit
    /// another `.bufferFinished` because it's already effectively playing — which
    /// left the spinner stuck on over a stream that was running. `notePlaybackProgress`
    /// is the ground-truth backstop that clears it.
    func updateLoadingState(_ state: KSPlayerState) {
        switch state {
        case .initialized, .preparing, .readyToPlay, .buffering:
            if !isBuffering {
                withAnimation(.easeInOut(duration: 0.25)) { isBuffering = true }
            }
        case .bufferFinished:
            markPlaybackStarted()
            if isBuffering {
                withAnimation(.easeInOut(duration: 0.25)) { isBuffering = false }
            }
        case .paused, .playedToTheEnd:
            if isBuffering {
                withAnimation(.easeInOut(duration: 0.25)) { isBuffering = false }
            }
        case .error:
            // Leave the spinner as-is: a drop during initial load keeps spinning
            // through the bounded reconnect (which returns to `.preparing`).
            break
        }
    }

    /// Ground-truth "frames are rendering" signal that clears the spinner even
    /// when the state callback settled on a non-`.bufferFinished` state and never
    /// recovered (see `updateLoadingState`). KSPlayer's 0.1s clock fires `onPlay`
    /// whenever the player is ready — including during a stall — so the tick alone
    /// isn't enough; but `currentPlaybackTime` only *advances* while frames are
    /// actually being presented. An advancing playhead therefore means the stream
    /// is playing, while a genuine stall or in-flight reconnect leaves it frozen
    /// (no advance → spinner stays). Cheap no-op once the spinner is already down.
    func notePlaybackProgress(_ current: TimeInterval) {
        guard current.isFinite, !isSeeking else { return }
        defer { lastPlayhead = current }
        guard isBuffering, lastPlayhead >= 0, current > lastPlayhead else { return }
        markPlaybackStarted()
        withAnimation(.easeInOut(duration: 0.25)) { isBuffering = false }
    }

    /// Record that the stream has produced its first frame. Unlocks the controls
    /// for good and disarms the startup watchdog (a dead-stream timeout is moot
    /// once frames are flowing). Idempotent.
    func markPlaybackStarted() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        cancelStartupWatchdog()
    }

    // MARK: - Reconnect

    /// React to a KSPlayer state change for reconnect purposes. A mid-stream
    /// failure lands the layer in `.error` and it sits there frozen; we drive a
    /// bounded backoff reconnect off that, and clear the budget once playback is
    /// confirmed healthy again. `.playedToTheEnd` is a clean finish, not a drop,
    /// so it is left alone.
    func handleState(_ state: KSPlayerState) {
        switch state {
        case .readyToPlay, .bufferFinished:
            reconnector.reset()
        case .error:
            reconnector.scheduleRetry { reconnect() }
            // Budget just exhausted on this drop: the stream is dead, so stop
            // spinning and offer Try Again / Back instead of freezing.
            if reconnector.hasGivenUp { failPlayback() }
        default:
            break
        }
    }

    // MARK: - Dead-stream handling

    /// Arm the startup watchdog. Started on open and on each stream swap; the
    /// first frame (`markPlaybackStarted`) disarms it.
    func startStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled, !hasStartedPlayback else { return }
            Logger.player.error("startup watchdog: no first frame within \(startupTimeout, format: .fixed(precision: 0), privacy: .public)s, declaring stream dead")
            failPlayback()
        }
    }

    func cancelStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    /// Give up on a stream that never started (or dropped for good). Tears down
    /// the spinner and pending reconnects and raises the failure overlay.
    func failPlayback() {
        guard !loadFailed else { return }
        cancelStartupWatchdog()
        reconnector.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            isBuffering = false
            loadFailed = true
        }
    }

    /// Re-prepare the current stream after a failure (the Try Again button).
    /// Resets the load gates, rearms the watchdog and reconnect budget, and
    /// rebuilds the stream in place.
    ///
    /// Unlike `reconnect()` — which leans on `play()` re-preparing from `.error`
    /// — this drives `prepareToPlay()` directly, so it also reloads a stream that
    /// merely *hung* in `.buffering`/`.preparing` (the startup-watchdog case),
    /// where `play()` would be a no-op because the layer never reached `.error`.
    func retryPlayback() {
        withAnimation(.easeInOut(duration: 0.25)) {
            loadFailed = false
            isBuffering = true
        }
        hasStartedPlayback = false
        lastPlayhead = -1
        reconnector.reset()
        #if os(tvOS)
            engine.reset()
        #endif
        startStartupWatchdog()

        guard let layer = coordinator.playerLayer else { return }
        if !media.isLive, clock.current > 1 {
            layer.options.startPlayTime = clock.current
        }
        Logger.player.log("retry: rebuilding KSPlayer stream from failure overlay")
        layer.prepareToPlay()
        // Ensure autoplay once the rebuilt input is ready (prepareToPlay only
        // arms preparation; play() sets isAutoPlay and resumes on ready).
        layer.play()
    }

    /// Re-prepare the current stream in place. `KSPlayerLayer.play()` calls
    /// `prepareToPlay()` whenever the layer is in `.error`, which rebuilds the
    /// input from scratch. VOD resumes near the drop point via `startPlayTime`
    /// (re-read on each prepare); live rejoins the live edge.
    func reconnect() {
        guard let layer = coordinator.playerLayer else { return }
        if !media.isLive, clock.current > 1 {
            layer.options.startPlayTime = clock.current
        }
        Logger.player.log("reconnect: reloading KSPlayer stream")
        layer.play()
    }
}
