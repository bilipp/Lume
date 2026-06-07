import Combine
import Foundation
import OSLog
import VLCKitSPM

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

    var onTime: ((TimeInterval) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?

    let mediaPlayer = VLCMediaPlayer()

    private weak var hostView: VLCHostView?
    private var isLive = false
    private var startTime: TimeInterval = 0
    private var didConfigure = false

    private var deinterlace = false

    private var needsResume = false
    private var didSeekResume = false
    private var resumeLanded = false

    /// PiP window controller, delivered by VLC once PiP is ready to use.
    private var pipController: (any VLCPictureInPictureWindowControlling)?

    private var statsTimer: Timer?
    private var lastStats: VLCMedia.Stats?
    private var lastStateName: String?
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

    func configure(media: PlayableMedia, deinterlace: Bool) {
        guard !didConfigure else { return }
        didConfigure = true

        VLCPlayerCoordinator.installLibVLCLogBridgeIfNeeded()
        isLive = media.isLive
        startTime = media.startTime
        needsResume = !media.isLive && media.startTime > 1
        self.deinterlace = deinterlace
        mediaURL = media.url
        retry.reset()
        mediaPlayer.delegate = self

        let vlcMedia = VLCMedia(url: media.url)
        applyMediaOptions(to: vlcMedia, isLive: media.isLive)
        mediaPlayer.media = vlcMedia
        // swiftlint:disable:next line_length
        Logger.player.log("configure: live=\(media.isLive, privacy: .public) startTime=\(media.startTime, format: .fixed(precision: 1), privacy: .public)s deinterlace=\(deinterlace, privacy: .public) url=\(media.url.absoluteString, privacy: .private(mask: .hash))")
        mediaPlayer.play()
        applyDeinterlace()
        isPlaying = true
        startStatsLogging()
    }

    private func applyMediaOptions(to media: VLCMedia?, isLive: Bool) {
        guard let media else { return }
        media.addOption(networkCaching(isLive: isLive))
        media.addOption(":avcodec-hw=videotoolbox")
        media.addOption(":avcodec-threads=0")
        media.addOption(deinterlace ? ":deinterlace=1" : ":deinterlace=0")
        media.addOption(":skip-frames")
        if deinterlace { media.addOption(":deinterlace-mode=blend") }
    }

    private func applyDeinterlace() {
        if deinterlace {
            mediaPlayer.setDeinterlace(.on, withFilter: "blend")
        } else {
            mediaPlayer.setDeinterlaceFilter(nil)
        }
    }

    private func networkCaching(isLive: Bool) -> String {
        isLive ? ":network-caching=3000" : ":network-caching=1500"
    }

    /// Swap the current stream for a different one without tearing down the
    /// player or its render surface. Used by the tvOS overlay to start a new
    /// episode picked from the in-player episode rail.
    func reload(media: PlayableMedia, deinterlace: Bool) {
        isLive = media.isLive
        startTime = media.startTime
        needsResume = !media.isLive && media.startTime > 1
        didSeekResume = false
        resumeLanded = false
        videoInfo = nil
        self.deinterlace = deinterlace
        mediaURL = media.url
        lastKnownTime = 0
        retry.reset()

        let vlcMedia = VLCMedia(url: media.url)
        applyMediaOptions(to: vlcMedia, isLive: media.isLive)
        mediaPlayer.media = vlcMedia
        // swiftlint:disable:next line_length
        Logger.player.log("reload: live=\(media.isLive, privacy: .public) startTime=\(media.startTime, format: .fixed(precision: 1), privacy: .public)s deinterlace=\(deinterlace, privacy: .public) url=\(media.url.absoluteString, privacy: .private(mask: .hash))")
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
    /// VLCKit 4 has no `.ended` state — a finished VOD and a self-initiated stop
    /// both surface as `.stopped`, while a mid-stream failure surfaces as
    /// `.error`. We always retry `.error`; we retry `.stopped` only for live
    /// streams (which never legitimately end), and not while a reconnect we
    /// just issued is still bringing the new media up.
    private func handleRetry(for state: VLCMediaPlayerState) {
        switch state {
        case .opening, .buffering, .playing:
            isReloading = false
            if state == .playing { retry.reset() }
        case .error:
            retry.scheduleRetry { [weak self] in self?.reconnect() }
        case .stopped where isLive && !isReloading:
            retry.scheduleRetry { [weak self] in self?.reconnect() }
        default:
            break
        }
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

        let vlcMedia = VLCMedia(url: mediaURL)
        applyMediaOptions(to: vlcMedia, isLive: isLive)
        mediaPlayer.media = vlcMedia
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

    // MARK: - Diagnostics

    private static var didInstallLogBridge = false

    private static func installLibVLCLogBridgeIfNeeded() {
        guard !didInstallLogBridge else { return }
        didInstallLogBridge = true
        VLCLibrary.shared().loggers = [VLCLogBridge()]
    }

    /// Begin periodic stream-health sampling. Idempotent. Debug-only: it's
    /// purely diagnostic and otherwise runs on the main runloop every 2s
    /// throughout playback, so it's compiled out of release builds.
    private func startStatsLogging() {
        lastStats = nil
        statsTimer?.invalidate()
        statsTimer = nil
        #if DEBUG
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.logStreamHealth()
            }
            // Common mode so sampling continues during scrolling / tracking
            // runloop activity in the player UI.
            RunLoop.main.add(timer, forMode: .common)
            statsTimer = timer
        #endif
    }

    private func stopStatsLogging() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastStats = nil
    }

    #if DEBUG
        /// Snapshot `VLCMedia.statistics` and log it as deltas since the previous
        /// sample, so the rate of dropped/late frames and discontinuities — the
        /// signals behind live-stream stutter — is directly readable. Cumulative
        /// counters are differenced; bitrates are instantaneous.
        private func logStreamHealth() {
            guard let stats = mediaPlayer.media?.statistics else { return }
            defer { lastStats = stats }

            let position = (mediaPlayer.time.value?.doubleValue ?? 0) / 1000
            let state = VLCMediaPlayerStateToString(mediaPlayer.state)

            // Deltas over the sample window (≈2s). First sample has no baseline.
            let prev = lastStats
            let dDisplayed = stats.displayedPictures - (prev?.displayedPictures ?? stats.displayedPictures)
            let dLate = stats.latePictures - (prev?.latePictures ?? stats.latePictures)
            let dLost = stats.lostPictures - (prev?.lostPictures ?? stats.lostPictures)
            let dLostAudio = stats.lostAudioBuffers - (prev?.lostAudioBuffers ?? stats.lostAudioBuffers)
            let dDiscont = stats.demuxDiscontinuity - (prev?.demuxDiscontinuity ?? stats.demuxDiscontinuity)
            let dCorrupt = stats.demuxCorrupted - (prev?.demuxCorrupted ?? stats.demuxCorrupted)

            let inputKbps = stats.inputBitrate * 8000 // bytes/ms → kbit/s
            let demuxKbps = stats.demuxBitrate * 8000

            Logger.player.debug(
                """
                health t=\(position, format: .fixed(precision: 1), privacy: .public)s state=\(state, privacy: .public) \
                input=\(inputKbps, format: .fixed(precision: 0), privacy: .public)kbps \
                demux=\(demuxKbps, format: .fixed(precision: 0), privacy: .public)kbps \
                displayed+\(dDisplayed, privacy: .public) late+\(dLate, privacy: .public) lost+\(dLost, privacy: .public) \
                audioLost+\(dLostAudio, privacy: .public) discont+\(dDiscont, privacy: .public) corrupt+\(dCorrupt, privacy: .public)
                """
            )

            // Call out the symptoms most associated with stutter at a level that
            // survives release-log filtering.
            if dLost > 0 || dLate > 0 || dDiscont > 0 || dLostAudio > 0 {
                Logger.player.warning(
                    "stutter signals: lost=\(dLost, privacy: .public) late=\(dLate, privacy: .public) discont=\(dDiscont, privacy: .public) audioLost=\(dLostAudio, privacy: .public) over ~2s"
                )
            }
        }
    #endif

    func tearDown() {
        stopStatsLogging()
        retry.cancel()
        Logger.player.log("tearDown")
        mediaPlayer.delegate = nil
        if mediaPlayer.isPlaying { mediaPlayer.stop() }
        mediaPlayer.drawable = nil
        pipController = nil
    }

    /// Pause playback when the app leaves the foreground (e.g. the tvOS Home
    /// button). `onDisappear`/`tearDown` don't fire on backgrounding — the view
    /// stays in the hierarchy — so VLC would otherwise keep playing audio.
    /// Skipped while Picture in Picture is active so PiP playback continues.
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

    // MARK: - Tracks

    var audioTracks: [VLCMediaPlayer.Track] {
        mediaPlayer.audioTracks
    }

    var textTracks: [VLCMediaPlayer.Track] {
        mediaPlayer.textTracks
    }

    func selectAudioTrack(_ track: VLCMediaPlayer.Track) {
        track.isSelectedExclusively = true
        objectWillChange.send()
    }

    func selectTextTrack(_ track: VLCMediaPlayer.Track?) {
        if let track {
            track.isSelectedExclusively = true
        } else {
            mediaPlayer.deselectAllTextTracks()
        }
        objectWillChange.send()
    }
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
        }
    }

    /// Log player state transitions, and measure how long each buffering
    /// episode lasts — frequent or long rebuffers are the clearest fingerprint
    /// of a struggling live stream.
    private func logStateChange() {
        let state = mediaPlayer.state
        let name = VLCMediaPlayerStateToString(state)
        guard name != lastStateName else { return }
        lastStateName = name

        if state == .buffering {
            bufferingStartedAt = Date()
            Logger.player.log("state → \(name, privacy: .public)")
        } else if let started = bufferingStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            bufferingStartedAt = nil
            Logger.player.log("state → \(name, privacy: .public) (rebuffered \(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
        } else {
            Logger.player.log("state → \(name, privacy: .public)")
        }

        // Re-assert deinterlace once a vout exists: the runtime setting doesn't
        // survive the output being (re)created, e.g. across a stream reload.
        if state == .playing { applyDeinterlace() }

        if state == .error {
            Logger.player.error("player entered error state")
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

    /// VLCPictureInPictureDrawable
    func mediaController() -> (any VLCPictureInPictureMediaControlling)? {
        self
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

// MARK: - libvlc log bridge

/// Forwards libvlc's internal log messages into `Logger.player`, mapping VLC
/// log levels onto the unified-logging levels so decoder/demux failures show
/// up under the `Player` category alongside our structured samples.
private final class VLCLogBridge: NSObject, VLCLogging {
    /// `.warning`, not `.info`: at info level libvlc logs at very high volume
    /// (some modules per packet/frame), each message costing a String bridge +
    /// os_log on the decode thread. Warnings and errors still come through.
    var level: VLCLogLevel = .warning

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        // Keychain HTTP-auth probe (errSecItemNotFound) — emitted per request,
        // harmless, and drowns out everything else. Drop it.
        if message.contains("lookup failed (-25300") { return }

        let module = context?.module ?? "vlc"
        switch logLevel {
        case .error:
            Logger.player.error("libvlc[\(module, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            Logger.player.warning("libvlc[\(module, privacy: .public)] \(message, privacy: .public)")
        case .info:
            Logger.player.info("libvlc[\(module, privacy: .public)] \(message, privacy: .public)")
        default:
            Logger.player.debug("libvlc[\(module, privacy: .public)] \(message, privacy: .public)")
        }
    }
}
