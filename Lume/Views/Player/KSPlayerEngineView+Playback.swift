import KSPlayer
import OSLog
import QuartzCore
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
            setBuffering(true)
        case .bufferFinished:
            // Ignore a stale .bufferFinished from the previous session that
            // can arrive in the window between retryPlayback() resetting the
            // state and the new session emitting its own .readyToPlay.
            guard hasSeenReadyToPlay else { return }
            markPlaybackStarted()
            setBuffering(false)
        case .paused:
            setBuffering(false)
        case .playedToTheEnd:
            // Live: server-side drop (404, segmenter restart) — keep the
            // spinner up while the reconnect delay elapses.
            // Non-live: normal end of file — clear the spinner.
            setBuffering(media.isLive)
        case .error:
            // Leave the spinner as-is: a drop during initial load keeps
            // spinning through the bounded reconnect (returns to .preparing).
            break
        }
    }

    /// Transition `isBuffering` with a standard ease animation, no-op when
    /// the value is already correct (avoids redundant SwiftUI diffs).
    private func setBuffering(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        withAnimation(.easeInOut(duration: 0.25)) { isBuffering = buffering }
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
        setBuffering(false)
    }

    /// Record that the stream has produced its first frame. Unlocks the controls
    /// for good and disarms the startup watchdog (a dead-stream timeout is moot
    /// once frames are flowing). Idempotent.
    ///
    /// Guarded by `hasSeenReadyToPlay` so a stale `.bufferFinished` callback
    /// from the *previous* session (which arrives after `retryPlayback()` resets
    /// `hasStartedPlayback`) cannot prematurely cancel the watchdog before the
    /// new session's prepare cycle has started.
    func markPlaybackStarted() {
        guard !hasStartedPlayback, hasSeenReadyToPlay else { return }
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
        // The stall watchdog lives exactly as long as a mid-playback `.buffering`
        // window on a live stream; any other state means the engine moved on.
        // Startup buffering is excluded — `startupTimeout` already covers it.
        if state == .buffering, hasStartedPlayback, media.isLive {
            startStallWatchdog()
        } else {
            cancelStallWatchdog()
        }
        switch state {
        case .readyToPlay:
            hasSeenReadyToPlay = true
            reconnector.reset()
        case .bufferFinished:
            // Guard: KSPlayerLayer.play() immediately sets state = .bufferFinished
            // if the previous session's loadState is still .playable (it isn't reset
            // by prepareToPlay). That stale callback fires before the new session
            // opens, so .readyToPlay hasn't been seen yet. Resetting the budget on
            // that stale signal causes an infinite loop on persistent failures (e.g.
            // 403 token expiry) — the counter resets to 0 every cycle and never
            // reaches the give-up threshold.
            if hasSeenReadyToPlay {
                reconnector.reset()
            }
        case .error:
            reconnector.scheduleRetry { reconnect() }
            // Budget just exhausted on this drop: the stream is dead, so stop
            // spinning and offer Try Again / Back instead of freezing.
            if reconnector.hasGivenUp { failPlayback() }
        case .playedToTheEnd:
            // A live stream that reaches .playedToTheEnd has had its HLS
            // playlist return 404 (server restart, token expiry, segmenter gap)
            // — KSPlayer retries the playlist a few times, gives up, and emits
            // this state rather than .error. Treat it as a recoverable drop and
            // reconnect with bounded backoff.
            if media.isLive {
                reconnector.scheduleRetry { reconnect() }
                if reconnector.hasGivenUp { failPlayback() }
            }
        default:
            break
        }
    }

    // MARK: - Mid-stream stall watchdog

    /// Rebuild a live stream that buffers without ever recovering.
    ///
    /// A decode error mid-stream (one corrupt packet after a network stall is
    /// enough) kills KSPlayer's decode thread for that track; with no frames
    /// ever decoded again the track can't satisfy the playable check, so the
    /// layer reports `.buffering` forever — and never `.error`, so the
    /// reconnector has nothing to react to. The startup watchdog is disarmed
    /// once the first frame rendered, leaving this window uncovered. A healthy
    /// live rebuffer only has to refill a few seconds of buffer, so a stall
    /// outliving `stallTimeout` means the pipeline is wedged: rebuild in place
    /// (`retryPlayback` re-prepares the input and rejoins the live edge).
    func startStallWatchdog() {
        guard stallWatchdog == nil else { return }
        stallWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(stallTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            stallWatchdog = nil
            Logger.player.error("stall watchdog: live stream stuck buffering for \(stallTimeout, format: .fixed(precision: 0), privacy: .public)s, rebuilding stream")
            retryPlayback()
        }
    }

    func cancelStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    // MARK: - Live clock-drift watchdog

    /// A/V clock divergence treated as unrecoverable. Normal playback keeps the
    /// sync diff within fractions of a second; the failure this watches for
    /// puts it at tens of thousands of seconds, so anything past a few seconds
    /// that *persists* means the timelines have split for good.
    private static let driftTolerance: TimeInterval = 10
    /// How long the divergence must persist before rebuilding. Filters the
    /// transient spikes a seek or discontinuity flush can produce.
    private static let driftPersistence: TimeInterval = 2
    /// Minimum spacing between drift-triggered rebuilds, so a stream whose
    /// timestamps are broken at the source can't thrash in a reload loop.
    private static let driftRecoveryCooldown: TimeInterval = 60

    /// Detect a runaway audio/video clock split on a live stream and rebuild
    /// the stream in place.
    ///
    /// FFmpeg's HLS demuxer tracks each rendition playlist independently; when
    /// a live mux crosses the MPEG-TS 33-bit timestamp wraparound (every
    /// ~26.5h of broadcast uptime) or the provider's segmenter restarts
    /// ("skipping N segments ahead, expired from playlists"), wraparound
    /// correction can land on one elementary stream but not the other. Audio —
    /// which renders unconditionally and drives the master clock — keeps
    /// playing, while every video frame now looks hours "late" and is dropped
    /// forever: frozen image, healthy sound, and no `.error` state for the
    /// reconnector to react to. Nothing app-side can rejoin the timelines;
    /// only re-preparing the input resets the demuxer.
    ///
    /// Polled from `onPlay` (KSPlayer's 0.1s tick, which keeps firing in this
    /// state because the audio clock still advances), watching the sync diff
    /// the video render loop publishes through `dynamicInfo`.
    func noteClockDrift() {
        guard media.isLive, hasStartedPlayback, !isSeeking, !loadFailed,
              let diff = coordinator.playerLayer?.player.dynamicInfo?.audioVideoSyncDiff,
              abs(diff) > Self.driftTolerance
        else {
            driftSince = nil
            return
        }
        let now = CACurrentMediaTime()
        guard let since = driftSince else {
            driftSince = now
            return
        }
        guard now - since >= Self.driftPersistence else { return }
        driftSince = nil
        guard now - lastDriftRecovery >= Self.driftRecoveryCooldown else { return }
        lastDriftRecovery = now
        Logger.player.error("clock-drift watchdog: A/V sync diff \(diff, format: .fixed(precision: 1), privacy: .public)s persisted, rebuilding live stream")
        retryPlayback()
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
        hasSeenReadyToPlay = false
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

    /// Re-prepare the current stream in place. For `.error` the layer's own
    /// `play()` calls `prepareToPlay()` internally; VOD resumes near the drop
    /// point via `startPlayTime` (re-read on each prepare).
    ///
    /// For live streams `play()` on a `.playedToTheEnd` layer calls
    /// `player.seek(time: 0)` — seeking to the DVR start, not the live edge.
    /// Always calling `prepareToPlay()` first on a live stream rebuilds the HLS
    /// session from scratch so we correctly rejoin the live edge in both the
    /// `.error` and `.playedToTheEnd` cases.
    func reconnect() {
        guard let layer = coordinator.playerLayer else { return }
        // Reset session gates so stale callbacks from the previous session don't
        // prematurely clear the spinner or reset the reconnect budget.
        hasSeenReadyToPlay = false
        lastPlayhead = -1
        if !media.isLive, clock.current > 1 {
            layer.options.startPlayTime = clock.current
        }
        Logger.player.log("reconnect: reloading KSPlayer stream")
        if media.isLive {
            layer.prepareToPlay()
        }
        layer.play()
    }
}
