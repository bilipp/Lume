import Combine
import Foundation
import OSLog
import VLCKit

#if canImport(UIKit)
    import UIKit

    typealias VLCHostView = UIView
#elseif canImport(AppKit)
    import AppKit

    typealias VLCHostView = NSView
#endif

/// Owns the `VLCMediaPlayer` and bridges it to SwiftUI.
///
/// The coordinator itself is the player's `drawable`: it conforms to
/// `VLCDrawable` (so VLC can insert its render surface into our host view)
/// and to the Picture-in-Picture protocols (`VLCPictureInPictureDrawable` /
/// `…MediaControlling`) so VLC 4 can drive an `AVPictureInPictureController`
/// internally. The PiP window controller is handed back via the
/// `pictureInPictureReady` block and stored in `pipController`.
///
/// VLC delegate callbacks may arrive off the main thread, so every UI-facing
/// mutation hops to the main actor.
final class VLCPlayerCoordinator: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var isPipActive = false
    @Published private(set) var isPipSupported = false

    /// True once the stream has actually started rendering. The host uses this
    /// to decide whether a failure is an initial-load failure (eligible for
    /// engine fallback) or a mid-stream drop.
    @Published private(set) var hasStartedPlayback = false

    /// Invoked when the stream can't be started: a hard `.error` before the
    /// first frame, or no frame at all within `startupTimeout`. The engine view
    /// either falls back to the next engine or raises the failure overlay.
    var onPlaybackFailure: (() -> Void)?

    /// How long to wait for the first frame before declaring the stream dead.
    /// Set by the host before `configure` — shorter when a fallback engine is
    /// available so the hand-off is prompt.
    var startupTimeout: TimeInterval = 40

    /// Live technical characteristics of the current video track, surfaced in
    /// the tvOS overlay's right-hand caption. `nil` until the demuxer has
    /// parsed the stream.
    @Published private(set) var videoInfo: PlayerVideoInfo?

    /// Current playback rate (1.0 == normal).
    var playbackRate: Float {
        get { mediaPlayer.rate }
        set {
            mediaPlayer.rate = newValue
            objectWillChange.send()
        }
    }

    /// Set before `configure` for a Multi-View tile: with several tiles playing
    /// at once, Picture in Picture belongs to the full-screen player alone. The
    /// rest of the embedded surface lives in `VLCPlayerCoordinator+MultiView`.
    var isEmbedded = false

    var onTime: ((TimeInterval) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?

    let mediaPlayer = VLCMediaPlayer()

    private weak var hostView: VLCHostView?
    private var isLive = false
    private var startTime: TimeInterval = 0
    private var didConfigure = false

    /// Snapshot of the user's VLCKit options, refreshed from `UserDefaults` each
    /// time a stream is configured or reloaded.
    private var options = VLCPlayerOptions.load()

    /// Snapshot of the viewer's preferred track languages, refreshed each time
    /// a stream is configured or reloaded — never mid-session, so a change in
    /// Settings applies the next time playback starts.
    var languageOptions = PlayerLanguageOptions(preferredAudioLanguages: [])

    /// Holds the preferred-language pass to once per opened stream; it is
    /// driven from the state change, which fires on every transition. Reset
    /// wherever the media is rebuilt, which hands libvlc fresh tracks.
    var didApplyPreferredLanguages = false

    /// A manual audio / subtitle pick outranks the preference for the rest of
    /// this stream. Kept across a same-URL rebuild (reconnect, Try Again) and
    /// cleared when the URL changes, so it cannot leak into the next channel.
    var hasManualTrackSelection = false

    private var needsResume = false
    private var didSeekResume = false
    private var resumeLanded = false

    /// PiP window controller, delivered by VLC once PiP is ready to use.
    private var pipController: (any VLCPictureInPictureWindowControlling)?

    var statsTimer: Timer?
    var lastStats: VLCMedia.Stats?
    /// Internal so `logStateChange()` can live in the +Diagnostics file, which
    /// exists to keep this one under the project's 600-line cap.
    var lastStateName: String?
    private var bufferingStartedAt: Date?

    /// Drives bounded backoff reconnects when the stream drops (see
    /// `handleRetry`).
    private let retry = PlaybackRetryController()
    /// Current stream URL, kept so a reconnect can rebuild the `VLCMedia`.
    private var mediaURL: URL?
    /// Last playback position reported to the UI — a reconnect resumes VOD here
    /// rather than restarting from the top.
    private var lastKnownTime: TimeInterval = 0
    /// True between issuing a reconnect and the new media starting to open, so
    /// the old media's trailing `.stopped` callback isn't mistaken for a fresh
    /// drop.
    private var isReloading = false

    /// Fires `onPlaybackFailure` if the stream produces no first frame within
    /// `startupTimeout` — covers a stream that hangs in `opening`/`buffering`
    /// forever without ever emitting `.error`.
    private var startupWatchdog: Task<Void, Never>?
    /// Guards `onPlaybackFailure` so a failure is reported at most once per load.
    private var didReportFailure = false

    // MARK: - Setup

    func attach(hostView: VLCHostView) {
        self.hostView = hostView
        #if canImport(UIKit)
            // iOS/tvOS: VLC inserts its render surface via the VLCDrawable
            // protocol (addSubview:/bounds), and the same object backs PiP.
            mediaPlayer.drawable = self
        #elseif canImport(AppKit)
            // macOS: VLCKit's sample-buffer display backend drives the
            // drawable as a genuine NSView — it sends frame/setFrame:/
            // removeFromSuperview: directly — so a custom VLCDrawable object
            // crashes with "unrecognized selector …frame". Render straight
            // into the host NSView instead.
            mediaPlayer.drawable = hostView
        #endif
    }

    func configure(media: PlayableMedia) {
        guard !didConfigure else { return }
        didConfigure = true

        VLCPlayerCoordinator.installLibVLCLogBridgeIfNeeded()
        isLive = media.isLive
        startTime = media.startTime
        needsResume = !media.isLive && media.startTime > 1
        options = VLCPlayerOptions.load()
        languageOptions = PlayerLanguageOptions.load()
        mediaURL = media.url
        retry.reset()
        hasStartedPlayback = false
        didReportFailure = false
        PlaybackQoE.shared.beginStartup(engine: .vlcKit, isLive: media.isLive)
        startStartupWatchdog()
        mediaPlayer.delegate = self

        installMedia(media.url, isLive: media.isLive)
        let deinterlaceOn = options.deinterlace
        // swiftlint:disable:next line_length
        Logger.player.log("configure: live=\(media.isLive, privacy: .public) startTime=\(media.startTime, format: .fixed(precision: 1), privacy: .public)s deinterlace=\(deinterlaceOn, privacy: .public) url=\(media.url.absoluteString, privacy: .private(mask: .hash))")
        mediaPlayer.play()
        applyDeinterlace()
        isPlaying = true
        startStatsLogging()
    }

    /// Every rebuild path goes through here: a fresh `VLCMedia` invalidates the
    /// track list, so the preferred-language latch must reset with it.
    private func installMedia(_ url: URL, isLive: Bool) {
        let media = VLCMedia(url: url)
        applyMediaOptions(to: media, isLive: isLive)
        mediaPlayer.media = media
        didApplyPreferredLanguages = false
    }

    private func applyMediaOptions(to media: VLCMedia?, isLive: Bool) {
        guard let media else { return }

        media.addOption(options.hardwareDecode ? ":avcodec-hw=videotoolbox" : ":avcodec-hw=none")
        media.addOption(":avcodec-threads=\(options.decodeThreads)")
        media.addOption(options.skipFrames ? ":skip-frames=1" : ":skip-frames=0")
        media.addOption(options.dropLateFrames ? ":drop-late-frames=1" : ":drop-late-frames=0")
        if options.httpReconnect { media.addOption(":http-reconnect=1") }

        media.addOption(options.deinterlace ? ":deinterlace=1" : ":deinterlace=0")
        if options.deinterlace { media.addOption(":deinterlace-mode=\(options.deinterlaceMode)") }

        // The original code set network-caching alongside the live/file caching
        // to the same value; the live and on-demand buffers keep that pairing.
        let buffer = isLive ? options.liveBuffer : options.vodBuffer
        media.addOption(":network-caching=\(buffer)")
        media.addOption(isLive ? ":live-caching=\(buffer)" : ":file-caching=\(buffer)")

        if let jitter = options.clockJitter { media.addOption(":clock-jitter=\(jitter)") }
        if let synchro = options.clockSynchro { media.addOption(":clock-synchro=\(synchro)") }
    }

    /// Internal so `logStateChange()` (in +Diagnostics) can re-assert it.
    func applyDeinterlace() {
        if options.deinterlace {
            mediaPlayer.setDeinterlace(.on, withFilter: options.deinterlaceMode)
        } else {
            mediaPlayer.setDeinterlaceFilter(nil)
        }
    }

    /// Swap the current stream for a different one without tearing down the
    /// player or its render surface. Used by the tvOS overlay to start a new
    /// episode picked from the in-player episode rail.
    func reload(media: PlayableMedia) {
        isLive = media.isLive
        startTime = media.startTime
        needsResume = !media.isLive && media.startTime > 1
        didSeekResume = false
        resumeLanded = false
        videoInfo = nil
        options = VLCPlayerOptions.load()
        languageOptions = PlayerLanguageOptions.load()
        if media.url != mediaURL { hasManualTrackSelection = false }
        mediaURL = media.url
        lastKnownTime = 0
        retry.reset()
        hasStartedPlayback = false
        didReportFailure = false
        PlaybackQoE.shared.beginStartup(engine: .vlcKit, isLive: media.isLive)
        startStartupWatchdog()

        installMedia(media.url, isLive: media.isLive)
        let deinterlaceOn = options.deinterlace
        // swiftlint:disable:next line_length
        Logger.player.log("reload: live=\(media.isLive, privacy: .public) startTime=\(media.startTime, format: .fixed(precision: 1), privacy: .public)s deinterlace=\(deinterlaceOn, privacy: .public) url=\(media.url.absoluteString, privacy: .private(mask: .hash))")
        mediaPlayer.play()
        applyDeinterlace()
        isPlaying = true
        startStatsLogging()
    }

    // MARK: - Reconnect

    /// React to a player state change for reconnect purposes: clear the budget
    /// once playback is healthy again, and schedule a backoff reconnect when
    /// the stream drops.
    ///
    private func handleRetry(for state: VLCMediaPlayerState) {
        switch state {
        case .opening, .playing:
            isReloading = false
            if state == .playing {
                retry.reset()
                hasStartedPlayback = true
                PlaybackQoE.shared.noteFirstFrame()
                cancelStartupWatchdog()
            }
        case .error:
            // A hard error before the first frame means this engine can't open
            // the stream — report it straight away so the host can fall back
            // (or raise the overlay) rather than retrying an engine that already
            // gave a definitive failure. After playback has started, fall back
            // on the bounded reconnect and only report once it's exhausted.
            if !hasStartedPlayback {
                reportFailure()
            } else {
                retry.scheduleRetry { [weak self] in self?.reconnect() }
                if retry.hasGivenUp { reportFailure() }
            }
        case .stopped where isLive && !isReloading:
            retry.scheduleRetry { [weak self] in self?.reconnect() }
            if retry.hasGivenUp { reportFailure() }
        default:
            break
        }
    }

    // MARK: - Failure handling

    /// Arm the startup watchdog. Cancelled once the first frame renders.
    private func startStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled, !hasStartedPlayback else { return }
            Logger.player.error("startup watchdog: no first frame within \(startupTimeout, format: .fixed(precision: 0), privacy: .public)s, declaring stream dead")
            reportFailure()
        }
    }

    private func cancelStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    /// Report a stream that couldn't be started. Fires `onPlaybackFailure` at
    /// most once per load; the engine view decides whether to fall back or show
    /// the failure overlay.
    private func reportFailure() {
        guard !didReportFailure else { return }
        didReportFailure = true
        if !hasStartedPlayback {
            PlaybackQoE.shared.noteStartupFailure()
        }
        cancelStartupWatchdog()
        retry.cancel()
        Logger.player.error("playback failure reported")
        onPlaybackFailure?()
    }

    /// Re-prepare the current stream after a failure (the Try Again button).
    /// Resets the failure gates and reconnect budget and rebuilds in place.
    func retryAfterFailure() {
        guard let mediaURL else { return }
        hasStartedPlayback = false
        didReportFailure = false
        retry.reset()
        startStartupWatchdog()

        installMedia(mediaURL, isLive: isLive)
        mediaPlayer.play()
        applyDeinterlace()
        isPlaying = true
        Logger.player.log("retry: reloading VLC stream from failure overlay")
    }

    /// Rebuild the current stream and resume playback in place. VOD resumes at
    /// the last reported position; live rejoins the live edge.
    private func reconnect() {
        guard let mediaURL else { return }
        Logger.player.log("reconnect: reloading stream")
        isReloading = true

        if !isLive, lastKnownTime > 1 {
            startTime = lastKnownTime
            needsResume = true
            didSeekResume = false
            resumeLanded = false
        }

        installMedia(mediaURL, isLive: isLive)
        mediaPlayer.play()
        applyDeinterlace()
        isPlaying = true
    }

    // MARK: - Video info

    /// Reads the current video track's resolution, frame rate and codec.
    /// Published only when the value actually changes to avoid view churn.
    private func refreshVideoInfo() {
        let size = mediaPlayer.videoSize
        let track = mediaPlayer.videoTracks.first

        var width = Int(size.width.rounded())
        var height = Int(size.height.rounded())
        var fps = 0.0
        var codec: String?

        if let track {
            if let video = track.video {
                if video.width > 0 { width = Int(video.width) }
                if video.height > 0 { height = Int(video.height) }
                let denominator = max(Int(video.frameRateDenominator), 1)
                if video.frameRate > 0 { fps = Double(video.frameRate) / Double(denominator) }
            }
            let name = track.codecName()
            codec = name.isEmpty ? nil : name
        }

        let info = (width > 0 && height > 0)
            ? PlayerVideoInfo(width: width, height: height, fps: fps, codec: codec)
            : nil
        if info != videoInfo { videoInfo = info }
    }

    // MARK: - Resume

    /// Seek to the saved position once the player reports it can seek.
    /// Safe to call repeatedly; it acts at most once.
    private func seekToResumeIfNeeded() {
        guard needsResume, !didSeekResume, mediaPlayer.isSeekable else { return }
        mediaPlayer.time = VLCTime(int: Int32((startTime * 1000).rounded()))
        didSeekResume = true
    }

    /// Whether playback time may be reported to the UI yet. While a resume
    /// seek is pending we withhold updates so the clock doesn't briefly
    /// show (and persist) the pre-seek position.
    private func isResumeSettled(currentSeconds: TimeInterval) -> Bool {
        guard needsResume else { return true }
        if resumeLanded { return true }
        if didSeekResume, currentSeconds >= startTime - 2 {
            resumeLanded = true
            return true
        }
        return false
    }

    func tearDown() {
        stopStatsLogging()
        retry.cancel()
        cancelStartupWatchdog()
        PlaybackQoE.shared.endSession()
        Logger.player.log("tearDown")
        mediaPlayer.delegate = nil
        if mediaPlayer.isPlaying { mediaPlayer.stop() }
        mediaPlayer.drawable = nil
        pipController = nil
    }

    func pauseForBackground() {
        guard !isPipActive, mediaPlayer.isPlaying else { return }
        mediaPlayer.pause()
        isPlaying = false
    }

    // MARK: - Transport

    func togglePlay() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
        isPlaying = mediaPlayer.isPlaying
    }

    func skip(by seconds: Double) {
        if seconds < 0 {
            mediaPlayer.jumpBackward(-seconds)
        } else {
            mediaPlayer.jumpForward(seconds)
        }
    }

    /// Seek to an absolute time (in seconds).
    func seek(to seconds: TimeInterval) {
        let millis = Int32((seconds * 1000).rounded())
        mediaPlayer.time = VLCTime(int: millis)
    }

    // MARK: - Picture in Picture

    func togglePictureInPicture() {
        guard let pipController else { return }
        if isPipActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    // Track listing and selection live in VLCPlayerCoordinator+Languages.
}

// MARK: - VLCMediaPlayerDelegate

extension VLCPlayerCoordinator: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_: VLCMediaPlayerState) {
        // Hop to main before touching the player: VLC invokes delegate
        // callbacks on its own event thread, and reentering libvlc from
        // there (e.g. the resume seek) can crash or deadlock.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            logStateChange()
            handleRetry(for: mediaPlayer.state)
            seekToResumeIfNeeded()
            isPlaying = mediaPlayer.isPlaying
            isPipSupported = pipController != nil
            pipController?.invalidatePlaybackState()
            refreshVideoInfo()
            applyPreferredLanguagesIfNeeded()
        }
    }

    /// Measure how long each buffering episode lasts — frequent or long
    /// rebuffers are the clearest fingerprint of a struggling live stream.
    /// VLCKit 4 reports buffering as a progress signal rather than a state:
    /// progress climbs to 1.0 when buffering completes.
    func mediaPlayerBufferingChanged(_ progress: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if progress >= 1.0 {
                PlaybackQoE.shared.noteStallEnded()
                if let started = bufferingStartedAt {
                    let elapsed = Date().timeIntervalSince(started)
                    bufferingStartedAt = nil
                    Logger.player.log("buffering complete (rebuffered \(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
                }
            } else if bufferingStartedAt == nil {
                // Mid-stream only; `PlaybackQoE` ignores stalls before the first
                // frame, which are join time rather than rebuffering.
                PlaybackQoE.shared.noteStallBegan()
                bufferingStartedAt = Date()
                Logger.player.log("buffering started")
            }
        }
    }

    func mediaPlayerTimeChanged(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            seekToResumeIfNeeded()
            let seconds = (mediaPlayer.time.value?.doubleValue ?? 0) / 1000
            guard isResumeSettled(currentSeconds: seconds) else { return }
            lastKnownTime = seconds
            onTime?(seconds)
            // Track characteristics are read on every state change; only chase
            // them from the high-frequency time callback until they first land,
            // so steady playback doesn't re-read tracks/codec each tick.
            if videoInfo == nil { refreshVideoInfo() }
        }
    }

    func mediaPlayerLengthChanged(_ length: Int64) {
        let seconds = Double(length) / 1000
        DispatchQueue.main.async { [weak self] in
            guard let self, seconds > 0 else { return }
            onDuration?(seconds)
            pipController?.invalidatePlaybackState()
        }
    }
}

// MARK: - VLCDrawable + Picture in Picture

extension VLCPlayerCoordinator: VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling {
    /// VLCDrawable — VLC inserts its output surface into our host view.
    func addSubview(_ view: VLCHostView) {
        guard let hostView else { return }
        view.frame = hostView.bounds
        #if canImport(UIKit)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #elseif canImport(AppKit)
            view.autoresizingMask = [.width, .height]
        #endif
        hostView.addSubview(view)
    }

    func bounds() -> CGRect {
        hostView?.bounds ?? .zero
    }

    /// VLCPictureInPictureDrawable. Returning `nil` is how a Multi-View tile
    /// opts out: on iOS/tvOS the coordinator has to be the drawable for VLC to
    /// render at all, so PiP is declined here rather than by withholding it.
    func mediaController() -> (any VLCPictureInPictureMediaControlling)? {
        isEmbedded ? nil : self
    }

    func pictureInPictureReady() -> ((any VLCPictureInPictureWindowControlling)?) -> Void {
        { [weak self] controller in
            guard let self else { return }
            pipController = controller
            controller?.stateChangeEventHandler = { [weak self] isStarted in
                DispatchQueue.main.async { self?.isPipActive = isStarted }
            }
            DispatchQueue.main.async { self.isPipSupported = controller != nil }
        }
    }

    /// VLCPictureInPictureMediaControlling — VLC drives playback from the PiP UI.
    func play() {
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        mediaPlayer.jump(withOffset: Int32(offset), completion: completion)
    }

    func mediaLength() -> Int64 {
        mediaPlayer.media?.length.value?.int64Value ?? 0
    }

    func mediaTime() -> Int64 {
        mediaPlayer.time.value?.int64Value ?? 0
    }

    func isMediaSeekable() -> Bool {
        mediaPlayer.isSeekable
    }

    func isMediaPlaying() -> Bool {
        mediaPlayer.isPlaying
    }
}
