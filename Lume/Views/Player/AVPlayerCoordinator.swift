import AVFoundation
import AVKit
import Combine
import CoreMedia
import Foundation
import OSLog

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Owns the `AVPlayer` + `AVPlayerLayer` and bridges them to SwiftUI, mirroring
/// the surface the VLCKit and KSPlayer coordinators expose so the three engines
/// can share one set of custom controls.
///
/// The engine view used to host an `AVPlayerViewController` and lean on AVKit's
/// built-in transport. To match the other two engines' Apple-TV-style overlay,
/// this renders straight into an `AVPlayerLayer` (so there are no native
/// controls to fight with) and re-implements transport, track selection,
/// content-mode and Picture in Picture on top.
///
/// KVO / time-observer callbacks may arrive off the main thread, so every
/// UI-facing mutation hops to the main actor — the same discipline the VLCKit
/// coordinator follows.
final class AVPlayerCoordinator: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    /// True while the player intends to play but is waiting on the buffer, so
    /// the host can raise a loading indicator (parity with KSPlayer/VLCKit).
    @Published private(set) var isBuffering = true
    @Published private(set) var isPipActive = false
    @Published private(set) var isPipSupported = false

    /// True once the stream has actually started playing. The host uses this to
    /// tell an initial-load failure (eligible for engine fallback) apart from a
    /// mid-stream drop.
    @Published private(set) var hasStartedPlayback = false

    /// Invoked when the stream can't be started: the item reports `.failed`, or
    /// no frame plays within `startupTimeout`. The engine view either falls back
    /// to the next engine or raises the failure overlay.
    var onPlaybackFailure: (() -> Void)?

    /// How long to wait for playback to start before declaring the stream dead.
    /// Set by the host before `configure` — shorter when a fallback engine is
    /// available so the hand-off is prompt.
    var startupTimeout: TimeInterval = 40

    /// Drives the content-mode (fit / fill) toggle in the overlay; applied to
    /// the player layer's `videoGravity`.
    @Published var isScaleAspectFill = false {
        didSet { applyVideoGravity() }
    }

    /// Live technical characteristics of the current video track, surfaced in
    /// the tvOS overlay's right-hand caption. `nil` until the item is ready.
    @Published private(set) var videoInfo: PlayerVideoInfo?

    /// Selectable audio / subtitle tracks, flattened for the overlay menus.
    @Published private(set) var audioTrackOptions: [PlayerTrackOption] = []
    @Published private(set) var textTrackOptions: [PlayerTrackOption] = []

    /// Current playback rate (1.0 == normal). Remembered across pause/resume so
    /// resuming honours a chosen speed.
    var playbackRate: Float {
        get { selectedRate }
        set {
            selectedRate = newValue
            if player.timeControlStatus != .paused {
                player.rate = newValue
            }
            objectWillChange.send()
        }
    }

    var onTime: ((TimeInterval) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?

    let player = AVPlayer()

    private weak var playerLayer: AVPlayerLayer?
    private var item: AVPlayerItem?

    private var isLive = false
    private var startTime: TimeInterval = 0
    private var needsResume = false
    private var didSeekResume = false
    private var selectedRate: Float = 1.0

    /// The stream currently loaded, kept so the failure-retry path can rebuild it.
    private var currentMedia: PlayableMedia?
    /// Fires `onPlaybackFailure` if playback never starts within `startupTimeout`.
    private var startupWatchdog: Task<Void, Never>?
    /// Guards `onPlaybackFailure` so a failure is reported at most once per load.
    private var didReportFailure = false

    // Cached media-selection groups so the overlay can map an opaque option id
    // back to the `AVMediaSelectionOption` to select.
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var legibleOptions: [AVMediaSelectionOption] = []

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var trackLoadTask: Task<Void, Never>?

    private var pipController: AVPictureInPictureController?

    override init() {
        player.automaticallyWaitsToMinimizeStalling = true
        super.init()
    }

    // MARK: - Layer attachment

    /// The container view hands its `AVPlayerLayer` over once it mounts. PiP can
    /// only be set up against a real layer, so it is wired here too.
    func attach(layer: AVPlayerLayer) {
        playerLayer = layer
        layer.player = player
        applyVideoGravity()
        setUpPictureInPicture(with: layer)
    }

    // MARK: - Configure / reload

    func configure(media: PlayableMedia) {
        load(media: media)
    }

    /// Swap the current stream for a different one without tearing down the
    /// player or its render surface — used when the viewer picks another episode
    /// or surfs to another live channel.
    func reload(media: PlayableMedia) {
        load(media: media)
    }

    private func load(media: PlayableMedia) {
        teardownItemObservers()
        trackLoadTask?.cancel()

        currentMedia = media
        isLive = media.isLive
        startTime = media.startTime
        needsResume = !media.isLive && media.startTime > 1
        didSeekResume = false
        videoInfo = nil
        audioTrackOptions = []
        textTrackOptions = []
        isBuffering = true
        hasStartedPlayback = false
        didReportFailure = false
        startStartupWatchdog()

        let asset = AVURLAsset(url: media.url)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = media.isLive ? 4 : 8
        item = newItem

        attachItemObservers(to: newItem)
        loadTracks(from: asset, item: newItem)

        player.replaceCurrentItem(with: newItem)
        // swiftlint:disable:next line_length
        Logger.player.log("AVPlayer load: live=\(media.isLive, privacy: .public) startTime=\(media.startTime, format: .fixed(precision: 1), privacy: .public)s url=\(media.url.absoluteString, privacy: .private(mask: .hash))")
        player.playImmediately(atRate: selectedRate)
    }

    // MARK: - Failure handling

    /// Arm the startup watchdog. Cancelled once playback actually starts.
    private func startStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled, !hasStartedPlayback else { return }
            Logger.player.error("AVPlayer startup watchdog: no playback within \(startupTimeout, format: .fixed(precision: 0), privacy: .public)s, declaring stream dead")
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
        cancelStartupWatchdog()
        Logger.player.error("AVPlayer playback failure reported")
        onPlaybackFailure?()
    }

    /// Re-prepare the current stream after a failure (the Try Again button).
    func retryAfterFailure() {
        guard let currentMedia else { return }
        load(media: currentMedia)
    }

    // MARK: - Teardown

    func tearDown() {
        teardownItemObservers()
        trackLoadTask?.cancel()
        cancelStartupWatchdog()
        pipController?.stopPictureInPicture()
        pipController = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerLayer?.player = nil
        Logger.player.log("AVPlayer tearDown")
    }

    func pauseForBackground() {
        guard !isPipActive, player.timeControlStatus != .paused else { return }
        player.pause()
    }

    // MARK: - Transport

    func togglePlay() {
        if player.timeControlStatus == .paused {
            player.playImmediately(atRate: selectedRate)
        } else {
            player.pause()
        }
    }

    func skip(by seconds: Double) {
        let current = player.currentTime().seconds
        let base = current.isFinite ? current : 0
        var target = base + seconds
        if let duration = item?.duration.seconds, duration.isFinite {
            target = min(target, duration)
        }
        seek(to: max(target, 0))
    }

    /// Seek to an absolute time (in seconds).
    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Picture in Picture

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    private func setUpPictureInPicture(with layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPipSupported = false
            return
        }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        #if os(iOS)
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        pipController = controller
        isPipSupported = controller != nil
    }

    // MARK: - Track selection

    func selectAudioTrack(id: String) {
        guard let audioGroup, let index = Int(id), audioOptions.indices.contains(index) else { return }
        item?.select(audioOptions[index], in: audioGroup)
        refreshTrackSelection()
    }

    /// `nil` disables subtitles ("Off").
    func selectTextTrack(id: String?) {
        guard let legibleGroup else { return }
        if let id, let index = Int(id), legibleOptions.indices.contains(index) {
            item?.select(legibleOptions[index], in: legibleGroup)
        } else {
            item?.select(nil, in: legibleGroup)
        }
        refreshTrackSelection()
    }

    private func loadTracks(from asset: AVAsset, item: AVPlayerItem) {
        trackLoadTask = Task { [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.item === item else { return }
                audioGroup = audio
                legibleGroup = legible
                audioOptions = audio?.options ?? []
                legibleOptions = legible?.options ?? []
                refreshTrackSelection()
            }
        }
    }

    /// Rebuild the published track lists from the item's current selection.
    private func refreshTrackSelection() {
        guard let item else {
            audioTrackOptions = []
            textTrackOptions = []
            return
        }
        let selection = item.currentMediaSelection

        if let audioGroup, audioOptions.count > 1 {
            let selected = selection.selectedMediaOption(in: audioGroup)
            audioTrackOptions = audioOptions.enumerated().map { index, option in
                PlayerTrackOption(id: String(index), label: option.displayName, isSelected: option == selected)
            }
        } else {
            audioTrackOptions = []
        }

        if let legibleGroup, !legibleOptions.isEmpty {
            let selected = selection.selectedMediaOption(in: legibleGroup)
            textTrackOptions = legibleOptions.enumerated().map { index, option in
                PlayerTrackOption(id: String(index), label: option.displayName, isSelected: option == selected)
            }
        } else {
            textTrackOptions = []
        }
    }

    // MARK: - Content mode

    private func applyVideoGravity() {
        playerLayer?.videoGravity = isScaleAspectFill ? .resizeAspectFill : .resizeAspect
    }

    // MARK: - Observers

    private func attachItemObservers(to item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let secs = time.seconds
            guard secs.isFinite else { return }
            MainActor.assumeIsolated { self.onTime?(secs) }
        }

        durationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            let secs = item.duration.seconds
            guard secs.isFinite, secs > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.onDuration?(secs) }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                DispatchQueue.main.async { [weak self] in
                    self?.seekToResumeIfNeeded()
                    self?.refreshVideoInfo()
                    self?.refreshTrackSelection()
                }
            case .failed:
                // The item can't be played (bad URL, unsupported container/codec).
                DispatchQueue.main.async { [weak self] in self?.reportFailure() }
            default:
                break
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isPlaying = player.timeControlStatus != .paused
                isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if player.timeControlStatus == .playing {
                    hasStartedPlayback = true
                    cancelStartupWatchdog()
                }
            }
        }

        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.refreshVideoInfo() }
        }
    }

    private func teardownItemObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil
    }

    // MARK: - Resume

    /// Seek to the saved position once the item is ready. Acts at most once.
    private func seekToResumeIfNeeded() {
        guard needsResume, !didSeekResume, let item, item.status == .readyToPlay else { return }
        didSeekResume = true
        let target = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Video info

    private func refreshVideoInfo() {
        let size = item?.presentationSize ?? .zero
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else {
            if videoInfo != nil { videoInfo = nil }
            return
        }
        let info = PlayerVideoInfo(width: width, height: height, fps: 0, codec: nil)
        if info != videoInfo { videoInfo = info }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension AVPlayerCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        isPipActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        isPipActive = false
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPipActive = false
        Logger.player.error("AVPlayer PiP failed to start: \(error.localizedDescription, privacy: .public)")
    }
}
