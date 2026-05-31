import AVFoundation
import AVKit
import SwiftUI

/// AVPlayer-backed video host.
///
/// On iOS / visionOS / Mac Catalyst this wraps `AVPlayerViewController` so we
/// get native scrubbing, captions, audio track selection, PiP, AirPlay routing
/// and the "LIVE" indicator for HLS streams. On AppKit macOS we fall back to
/// SwiftUI's `VideoPlayer` (`AVPlayerView` under the hood).
struct AVPlayerEngineView: View {
    let media: PlayableMedia
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    var body: some View {
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
            AVPlayerControllerHost(media: media, currentTime: $currentTime, duration: $duration)
        #else
            AVPlayerVideoHost(media: media, currentTime: $currentTime, duration: $duration)
        #endif
    }
}

// MARK: - Shared player observation

/// Owns the AVPlayer + AVPlayerItem and exposes progress via callbacks.
/// Intentionally non-actor-isolated; KVO callbacks hop to the main thread
/// before invoking consumer closures.
final class PlayerObservation {
    let player: AVPlayer
    private let item: AVPlayerItem
    private let isLive: Bool
    private let startTime: TimeInterval

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var didSeekToStart = false

    var onTime: (@MainActor (TimeInterval) -> Void)?
    var onDuration: (@MainActor (TimeInterval) -> Void)?

    init(media: PlayableMedia) {
        let asset = AVURLAsset(url: media.url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = media.isLive ? 4 : 8
        self.item = item
        isLive = media.isLive
        startTime = media.startTime

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        attachObservers()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        statusObservation?.invalidate()
        durationObservation?.invalidate()
    }

    @MainActor
    func startPlayback() {
        player.play()
    }

    @MainActor
    func tearDown() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    private func attachObservers() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let secs = time.seconds
            guard secs.isFinite else { return }
            MainActor.assumeIsolated {
                self.onTime?(secs)
            }
        }

        durationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            let secs = item.duration.seconds
            guard secs.isFinite, secs > 0 else { return }
            Task { @MainActor [weak self] in
                self?.onDuration?(secs)
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            let status = item.status
            let target = startTime
            let live = isLive
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == .readyToPlay, !didSeekToStart, !live, target > 1 {
                    didSeekToStart = true
                    let cmTime = CMTime(seconds: target, preferredTimescale: 600)
                    await player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }
}

// MARK: - iOS / visionOS / Mac Catalyst

#if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
    private struct AVPlayerControllerHost: UIViewControllerRepresentable {
        let media: PlayableMedia
        @Binding var currentTime: TimeInterval
        @Binding var duration: TimeInterval

        func makeCoordinator() -> Coordinator {
            Coordinator(media: media)
        }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.entersFullScreenWhenPlaybackBegins = false
            controller.exitsFullScreenWhenPlaybackEnds = false
            controller.showsPlaybackControls = true
            controller.videoGravity = .resizeAspect
            controller.updatesNowPlayingInfoCenter = true
            controller.player = context.coordinator.observation.player

            context.coordinator.observation.onTime = { currentTime = $0 }
            context.coordinator.observation.onDuration = { duration = $0 }
            context.coordinator.observation.startPlayback()
            return controller
        }

        func updateUIViewController(_: AVPlayerViewController, context _: Context) {}

        static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
            MainActor.assumeIsolated {
                coordinator.observation.tearDown()
            }
            controller.player = nil
        }

        final class Coordinator {
            let observation: PlayerObservation
            init(media: PlayableMedia) {
                observation = PlayerObservation(media: media)
            }
        }
    }
#endif

// MARK: - AppKit macOS fallback

#if os(macOS) && !targetEnvironment(macCatalyst)
    private struct AVPlayerVideoHost: View {
        let media: PlayableMedia
        @Binding var currentTime: TimeInterval
        @Binding var duration: TimeInterval

        @State private var observation: PlayerObservation

        init(media: PlayableMedia, currentTime: Binding<TimeInterval>, duration: Binding<TimeInterval>) {
            self.media = media
            _currentTime = currentTime
            _duration = duration
            _observation = State(initialValue: PlayerObservation(media: media))
        }

        var body: some View {
            VideoPlayer(player: observation.player)
                .onAppear {
                    observation.onTime = { currentTime = $0 }
                    observation.onDuration = { duration = $0 }
                    observation.startPlayback()
                }
                .onDisappear {
                    observation.tearDown()
                }
        }
    }
#endif

#Preview {
    AVPlayerEngineView(
        media: PlayableMedia(
            id: "preview",
            url: URL(string: "https://example.com/stream.m3u8")!,
            title: "Sample Video",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("preview")
        ),
        currentTime: .constant(0),
        duration: .constant(120)
    )
    .preferredColorScheme(.dark)
}
