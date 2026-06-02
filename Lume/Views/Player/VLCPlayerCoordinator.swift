import Combine
import Foundation

#if canImport(VLCKitSPM)
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

        // Resume state. Rather than VLC's `:start-time` media option — which
        // seeks the picture but makes the playback clock report from 0 on many
        // stream types — we seek explicitly once the player is seekable and
        // suppress time reporting until that seek lands, so the scrubber/clock
        // reflect the true position and we never persist a bogus 0.
        private var needsResume = false
        private var didSeekResume = false
        private var resumeLanded = false

        /// PiP window controller, delivered by VLC once PiP is ready to use.
        private var pipController: (any VLCPictureInPictureWindowControlling)?

        // MARK: - Setup

        func attach(hostView: VLCHostView) {
            self.hostView = hostView
            mediaPlayer.drawable = self
        }

        func configure(media: PlayableMedia) {
            guard !didConfigure else { return }
            didConfigure = true

            isLive = media.isLive
            startTime = media.startTime
            needsResume = !media.isLive && media.startTime > 1
            mediaPlayer.delegate = self

            let vlcMedia = VLCMedia(url: media.url)
            // Larger network buffer for live IPTV streams reduces stutter.
            vlcMedia?.addOption(media.isLive ? ":network-caching=3000" : ":network-caching=1500")
            mediaPlayer.media = vlcMedia
            mediaPlayer.play()
            isPlaying = true
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

    // MARK: - VLCMediaPlayerDelegate

    extension VLCPlayerCoordinator: VLCMediaPlayerDelegate {
        func mediaPlayerStateChanged(_: VLCMediaPlayerState) {
            // Hop to main before touching the player: VLC invokes delegate
            // callbacks on its own event thread, and reentering libvlc from
            // there (e.g. the resume seek) can crash or deadlock.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                seekToResumeIfNeeded()
                isPlaying = mediaPlayer.isPlaying
                isPipSupported = pipController != nil
                pipController?.invalidatePlaybackState()
            }
        }

        func mediaPlayerTimeChanged(_: Notification!) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                seekToResumeIfNeeded()
                let seconds = (mediaPlayer.time.value?.doubleValue ?? 0) / 1000
                guard isResumeSettled(currentSeconds: seconds) else { return }
                onTime?(seconds)
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

#endif
