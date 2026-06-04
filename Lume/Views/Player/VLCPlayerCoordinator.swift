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
        mediaPlayer.delegate = self

        let vlcMedia = VLCMedia(url: media.url)
        applyMediaOptions(to: vlcMedia, isLive: media.isLive)
        mediaPlayer.media = vlcMedia
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

        let vlcMedia = VLCMedia(url: media.url)
        applyMediaOptions(to: vlcMedia, isLive: media.isLive)
        mediaPlayer.media = vlcMedia
        Logger.player.log("reload: live=\(media.isLive, privacy: .public) startTime=\(media.startTime, format: .fixed(precision: 1), privacy: .public)s deinterlace=\(deinterlace, privacy: .public) url=\(media.url.absoluteString, privacy: .private(mask: .hash))")
        mediaPlayer.play()
        applyDeinterlace()
        isPlaying = true
        startStatsLogging()
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

    /// Begin periodic stream-health sampling. Idempotent.
    private func startStatsLogging() {
        lastStats = nil
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.logStreamHealth()
        }
        // Common mode so sampling continues during scrolling / tracking runloop
        // activity in the player UI.
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStatsLogging() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastStats = nil
    }

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
            seekable=\(self.mediaPlayer.isSeekable, privacy: .public) \
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

    func tearDown() {
        stopStatsLogging()
        Logger.player.log("tearDown")
        mediaPlayer.delegate = nil
        if mediaPlayer.isPlaying { mediaPlayer.stop() }
        mediaPlayer.drawable = nil
        pipController = nil
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

// MARK: - Video info

/// Resolution / frame-rate / codec snapshot for the current video track.
struct PlayerVideoInfo: Equatable {
    let width: Int
    let height: Int
    let fps: Double
    let codec: String?

    /// A short marketing-style quality tag derived from the pixel height.
    var qualityTag: String {
        // TEMP: show the actual full resolution instead of the marketing tag.
        // Restore the switch below to go back to "4K" / "1080p" labels.
        "\(height)p"
    }

    /// Compact pieces for the overlay's right-hand technical caption, e.g.
    /// `["4K", "H264", "24 fps"]`.
    var captionParts: [String] {
        var parts: [String] = []
        if !qualityTag.isEmpty { parts.append(qualityTag) }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if fps > 0 {
            let rounded = (fps * 100).rounded() / 100
            let text = rounded.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", rounded)
                : String(format: "%.2f", rounded)
            parts.append("\(text) fps")
        }
        return parts
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

    func mediaPlayerTimeChanged(_: Notification!) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            seekToResumeIfNeeded()
            let seconds = (mediaPlayer.time.value?.doubleValue ?? 0) / 1000
            guard isResumeSettled(currentSeconds: seconds) else { return }
            onTime?(seconds)
            refreshVideoInfo()
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
    var level: VLCLogLevel = .info

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
