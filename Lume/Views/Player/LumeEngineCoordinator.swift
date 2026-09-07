import AVFoundation
import Combine
import Foundation
import LumeEngine
import OSLog
import SwiftUI

/// Holds the engine's active subtitle cue text, refreshed from the coordinator's
/// 10 Hz playback tick. Deliberately a separate `ObservableObject` from
/// `LumeEngineCoordinator`: were the cue text `@Published` on the coordinator,
/// every per-tick update would fire the coordinator's `objectWillChange` and
/// re-render every overlay that observes it — flickering an open audio/subtitle
/// `Menu` and cancelling in-flight taps. Only the subtitle-rendering leaf
/// observes this model, so a cue change invalidates that leaf alone. Mirrors why
/// KSPlayer keeps its `SubtitleModel` off the controls overlay's observed surface.
@MainActor
final class SubtitleCueModel: ObservableObject {
    @Published private(set) var text: String?

    /// Assigns only on an actual change, so an unchanged cue repeated across
    /// ticks doesn't invalidate the leaf ten times a second.
    func update(_ newText: String?) {
        if text != newText {
            text = newText
        }
    }
}

/// Playback surface for the LumeEngine (FFmpeg) backend.
///
/// Wraps a `PlayerSession` per stream — the engine has no rebuild-in-place, so
/// `configure`/`reload` always tear the old session down and build a fresh one
/// (which is exactly the semantics `FullScreenPlayerView` expects from
/// `.id(engineAttempt)` teardown). Mirrors the coordinator surface of
/// `AVPlayerCoordinator`/`VLCPlayerCoordinator` so overlays stay engine-agnostic.
@MainActor
final class LumeEngineCoordinator: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// Set once the first frames are rendering; drives the loading indicator
    /// and the startup-failure watchdog.
    @Published private(set) var hasStartedPlayback = false
    @Published private(set) var videoInfo: PlayerVideoInfo?
    @Published private(set) var audioTrackOptions: [PlayerTrackOption] = []
    @Published private(set) var textTrackOptions: [PlayerTrackOption] = []
    @Published private(set) var isPipActive = false
    /// Active subtitle cue text, on its own observable so the 10 Hz tick that
    /// refreshes it doesn't invalidate this coordinator. A `@Published` here
    /// would fire `objectWillChange` on every tick, re-rendering every overlay
    /// that observes the coordinator (iOS `LumeEngineControlsOverlay`, tvOS
    /// `TVPlayerControlsOverlay`) — which flickers an open audio/subtitle `Menu`
    /// and cancels in-flight taps. Only the subtitle-rendering leaf observes
    /// this model, so a cue change invalidates that leaf alone.
    let subtitleCues = SubtitleCueModel()

    var isPipSupported: Bool {
        pipBridge?.isSupported ?? false
    }

    var playbackRate: Float = 1.0 {
        didSet {
            let session = session
            let rate = playbackRate
            Task { await session?.setRate(rate) }
        }
    }

    /// 10 Hz playback tick: (current, duration) in media-relative seconds.
    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    /// Initial-load failure (hard error or startup timeout before first frame).
    var onPlaybackFailure: (() -> Void)?
    /// Mid-stream stall after playback had started (the engine's watchdog);
    /// the view routes this through `PlaybackRetryController`.
    var onStalled: (() -> Void)?
    /// Playback reached a healthy playing state — the view resets its
    /// reconnect budget.
    var onRecovered: (() -> Void)?
    var startupTimeout: TimeInterval = 40

    /// Silences this player without pausing it — Multi-View mutes every tile
    /// except the one carrying the audio.
    var isMuted = false {
        didSet { session?.renderer.isMuted = isMuted }
    }

    /// Set before `configure` for a Multi-View tile: with several tiles playing
    /// at once, Picture in Picture belongs to the full-screen player alone.
    var isEmbedded = false

    /// The engine's video surface for the hosting representable.
    private(set) var displayLayer: LumeDisplayLayer?

    private var session: PlayerSession?
    private var pipBridge: PictureInPictureBridge?
    private var mediaInfo: MediaInfo?
    private var currentMedia: PlayableMedia?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// 10 Hz tick counter driving the diagnostics heartbeat cadence.
    private var tickCount = 0
    private var startupTask: Task<Void, Never>?
    private var reportedFailure = false
    /// Mirrors `PlayerSession.selectedAudioTrackIndex`, read back after `open`
    /// rather than assumed: the engine starts on its own preferred/default
    /// pick, which is not necessarily the first track.
    private var selectedAudioID: String?
    private var selectedSubtitleID: String?
    /// A manual pick in the audio or subtitle menu outranks the preferred
    /// languages for the rest of this stream: the engine has no rebuild in
    /// place, so a stall recovery re-opens through `makeConfiguration` and
    /// would otherwise re-assert the preference over the viewer's choice.
    /// Cleared when the URL changes, so it cannot leak into the next channel
    /// or episode. Persisted nowhere.
    private var hasManualTrackSelection = false
    /// The sidecar subtitle file loaded from the OpenSubtitles search, if any.
    /// Kept so the track survives a switch to an embedded track and back — the
    /// engine's sidecar loader is a one-shot parse, so re-selecting means
    /// re-reading the file.
    private var externalSubtitle: ExternalSubtitle?

    // MARK: Lifecycle

    func configure(media: PlayableMedia) {
        tearDown()
        if media.url != currentMedia?.url {
            hasManualTrackSelection = false
        }
        currentMedia = media
        reportedFailure = false
        // After `tearDown` (which closes any previous session) so a reload counts
        // as its own startup attempt rather than extending the last one.
        PlaybackQoE.shared.beginStartup(engine: .lumeEngine, isLive: media.isLive)

        let session = PlayerSession(configuration: makeConfiguration(for: media))
        self.session = session
        displayLayer = session.renderer.displayLayer
        session.renderer.audioTimePitchAlgorithm = .timeDomain
        session.renderer.isMuted = isMuted

        eventTask = Task { [events = session.events] in
            for await event in events {
                self.handle(event: event)
            }
        }
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self.tick()
            }
        }
        startupTask = makeStartupWatchdog()

        Task {
            do {
                let info = try await session.open(url: media.url.absoluteString)
                self.mediaInfo = info
                self.selectedAudioID = await session.selectedAudioTrackIndex.map { String($0) }
                // Non-nil only when the engine turned a forced track on by
                // itself because the chosen audio is foreign to the viewer;
                // embedded subtitles otherwise start off as they always have.
                self.selectedSubtitleID = await session.selectedSubtitleTrackIndex.map { String($0) }
                self.publishTracks(info: info)
                self.publishVideoInfo(info: info)
                if !self.isEmbedded {
                    self.pipBridge = PictureInPictureBridge(session: session, mediaInfo: info)
                }
                // Resume position is handled by the engine via
                // configuration.startPosition (seek-before-first-read).
                if media.startTime > 1, !media.isLive, !info.isSeekable {
                    Logger.player.warning("LumeEngine cannot resume: source is not seekable")
                }
                await session.play()
            } catch {
                self.reportFailure()
            }
        }
    }

    /// Startup failure watchdog. The window is rolling while the engine
    /// demonstrably downloads: a multi-second buffer target on a ~1× link
    /// legitimately pre-buffers past any fixed window, while a dead stream
    /// shows no byte progress and still fails within `startupTimeout`. A hard
    /// cap bounds pathological "downloads but never starts" cases.
    private func makeStartupWatchdog() -> Task<Void, Never> {
        Task { [startupTimeout] in
            let hardDeadline = Date(timeIntervalSinceNow: max(startupTimeout * 3, 60))
            var deadline = Date(timeIntervalSinceNow: startupTimeout)
            var lastBytes: Int64 = 0
            while !Task.isCancelled, !self.hasStartedPlayback {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.hasStartedPlayback else { return }
                if let session = self.session {
                    let bytes = await session.diagnostics.deliveredBytes
                    if bytes > lastBytes {
                        lastBytes = bytes
                        deadline = min(Date(timeIntervalSinceNow: startupTimeout), hardDeadline)
                    }
                }
                if Date() >= deadline {
                    Logger.player.error("LumeEngine startup window elapsed (read \(lastBytes) bytes, never played)")
                    self.reportFailure()
                    return
                }
            }
        }
    }

    /// Fresh session for the same stream (stall recovery), resuming from the
    /// current position for VOD.
    func reload() {
        guard var media = currentMedia else { return }
        if media.kind == .vod, let session {
            let resumeAt = sessionPositionSnapshot(session)
            media = media.resuming(at: resumeAt)
        }
        configure(media: media)
    }

    func tearDown() {
        PlaybackQoE.shared.endSession()
        eventTask?.cancel()
        tickTask?.cancel()
        startupTask?.cancel()
        eventTask = nil
        tickTask = nil
        startupTask = nil
        pipBridge = nil
        if let session {
            Task { await session.shutdown() }
        }
        session = nil
        mediaInfo = nil
        displayLayer = nil
        isPlaying = false
        isBuffering = false
        hasStartedPlayback = false
        subtitleCues.update(nil)
        // The sidecar lane belongs to the session that just went away; a fresh
        // session starts with no cues, so the menu must not keep advertising it.
        externalSubtitle = nil
        selectedAudioID = nil
        selectedSubtitleID = nil
        isPipActive = false
    }

    // MARK: Transport

    func togglePlay() {
        let session = session
        let playing = isPlaying
        Task {
            if playing {
                await session?.pause()
            } else {
                await session?.play()
            }
        }
    }

    func skip(by seconds: Double) {
        let session = session
        Task {
            guard let session else { return }
            let position = await session.position
            await session.seek(to: max(0, position + seconds))
        }
    }

    func seek(to seconds: TimeInterval) {
        let session = session
        Task { await session?.seek(to: seconds) }
    }

    func togglePictureInPicture() {
        pipBridge?.toggle()
        isPipActive = pipBridge?.isActive ?? false
    }

    // MARK: Tracks

    func selectAudioTrack(id: String) {
        guard let index = Int32(id) else { return }
        hasManualTrackSelection = true
        let session = session
        Task { await session?.selectAudioTrack(index) }
        selectedAudioID = id
        if let info = mediaInfo {
            publishTracks(info: info)
        }
    }

    func selectTextTrack(id: String?) {
        hasManualTrackSelection = true
        selectedSubtitleID = id
        if let external = externalSubtitle, id == Self.externalTrackID {
            loadExternalSubtitleFile(external)
            return
        }
        let session = session
        let index = id.flatMap(Int32.init)
        Task { await session?.selectSubtitleTrack(index) }
        if id == nil {
            subtitleCues.update(nil)
        }
        if let info = mediaInfo {
            publishTracks(info: info)
        }
    }

    // MARK: Internals

    /// Builds the session configuration from the stored Lume Engine options
    /// (Settings → Lume Engine Options), re-read on every configure/reload.
    private func makeConfiguration(for media: PlayableMedia) -> PlayerConfiguration {
        let options = LumeEngineOptions.load()
        var configuration = PlayerConfiguration()
        // Resume position goes through the engine (seek-before-first-read):
        // an open-then-seek from here seeks a connection that is already
        // streaming, which some IPTV providers kill (dead stream, no data).
        if media.startTime > 1, !media.isLive {
            configuration.startPosition = media.startTime
        }
        configuration.hardwareDecode = options.hardwareDecode ? .videoToolbox : .software
        configuration.deinterlace = Self.deinterlacing(for: options)
        configuration.bufferTarget = Double(media.isLive ? options.liveBuffer : options.vodBuffer) / 1000
        configuration.videoQueueDepth = options.videoQueueDepth
        configuration.audioQueueDepth = options.audioQueueDepth
        configuration.stallThreshold = Double(options.stallThreshold)
        // Resolved engine-side while the pipeline is built, before the demuxer
        // streams a byte: selecting after `open()` would route through a seek
        // that discards `startPosition` on a VOD resume and that many live IPTV
        // endpoints do not survive. Empty lists (the default, and what a manual
        // pick leaves for the rest of this stream) mean the engine keeps the
        // container's own selection.
        if !hasManualTrackSelection {
            let languages = PlayerLanguageOptions.load()
            configuration.preferredAudioLanguages = languages.preferredAudioLanguages
            // Subtitling untranslated dialogue is Lume's rule, not the
            // engine's — the same one `AVPlayerCoordinator+Languages` applies
            // on AVFoundation.
            configuration.autoEnableForcedSubtitlesForForeignAudio = true
        }
        configuration.demuxer.enableReconnect = options.httpReconnect
        configuration.demuxer.ioTimeout = options.ioTimeout
        // The open timeout stays tied to the engine-fallback budget rather than
        // a user option, so the fallback chain keeps its timing guarantees.
        configuration.demuxer.openTimeout = startupTimeout
        if let probeSize = options.probeSize {
            configuration.demuxer.probeSize = probeSize
        }
        if let analyzeDuration = options.analyzeDuration {
            configuration.demuxer.maxAnalyzeDuration = analyzeDuration
        }
        return configuration
    }

    /// Translates the stored deinterlace choices into the engine's policy.
    /// Kept out of `makeConfiguration` so it stays a pure mapping between two
    /// vocabularies — Lume's settings on one side, the engine's on the other.
    private static func deinterlacing(for options: LumeEngineOptions) -> VideoDecoder.Deinterlacing {
        let mode: VideoDecoder.Deinterlacing.Mode = switch options.deinterlaceMode {
        case .off: .off
        case .auto: .auto
        case .always: .always
        }
        let rate: VideoDecoder.Deinterlacing.Rate = switch options.deinterlaceRate {
        case .field: .field
        case .frame: .frame
        }
        return VideoDecoder.Deinterlacing(mode: mode, rate: rate)
    }

    private func handle(event: PlayerEvent) {
        switch event {
        case let .stateChanged(state):
            Logger.player.info("LumeEngine state → \(String(describing: state), privacy: .public)")
            isPlaying = state == .playing
            isBuffering = state == .buffering || state == .opening
            if isBuffering {
                PlaybackQoE.shared.noteStallBegan()
            } else {
                PlaybackQoE.shared.noteStallEnded()
            }
            if state == .playing {
                hasStartedPlayback = true
                PlaybackQoE.shared.noteFirstFrame()
                onRecovered?()
            }
            if state == .failed {
                // Local copy: os_log interpolation is an autoclosure; swiftformat strips `self.`
                let started = hasStartedPlayback
                Logger.player.error("LumeEngine failed (hasStartedPlayback: \(started))")
                if hasStartedPlayback {
                    onStalled?()
                } else {
                    reportFailure()
                }
            }
        case let .stalled(position):
            Logger.player.warning("LumeEngine stalled at \(position, format: .fixed(precision: 2))s")
            onStalled?()
        case let .error(error):
            Logger.player.error("LumeEngine error: \(LogRedaction.scrubURLs(in: String(describing: error)), privacy: .public)")
        case let .didSeek(position):
            Logger.player.info("LumeEngine didSeek → \(position, format: .fixed(precision: 2))s")
        case let .decoderDowngraded(error):
            Logger.player.warning("LumeEngine decoder downgraded: \(LogRedaction.scrubURLs(in: String(describing: error)), privacy: .public)")
        case .opened:
            break
        }
    }

    private func tick() async {
        guard let session else { return }
        let position = await session.position
        let duration = await session.duration ?? 0
        onTime?(position, duration)

        // Pipeline-health heartbeat: every ~3 s until playback settles, then
        // every ~30 s. Ground truth for triaging device-only failures (silent
        // audio, wedged buffering, throttled delivery) from a sysdiagnose or
        // Console stream without a debugger.
        tickCount += 1
        let heartbeatEvery = hasStartedPlayback && isPlaying ? 300 : 30
        if tickCount % heartbeatEvery == 0 {
            let diagnostics = await session.diagnostics
            Logger.player.info("LumeEngine \(diagnostics.description, privacy: .public)")
        }

        let now = session.renderer.currentTime
        if now != .min {
            let cues = session.subtitles.activeCues(at: now)
            let text = cues.map(\.text).joined(separator: "\n")
            subtitleCues.update(text.isEmpty ? nil : text)
        }
    }

    private func publishTracks(info: MediaInfo) {
        // `selectedAudioID` mirrors the engine's own `selectedAudioTrackIndex`,
        // which it sets whenever an audio track exists. Falling back to the
        // first row while it is still nil keeps the menu from rendering with no
        // checkmark at all.
        let audioFallsBackToFirst = selectedAudioID == nil
        audioTrackOptions = info.audioTracks.enumerated().map { position, track in
            let id = String(track.index)
            return PlayerTrackOption(
                id: id,
                label: trackLabel(track, fallback: "Audio \(position + 1)"),
                isSelected: selectedAudioID == id || (audioFallsBackToFirst && position == 0)
            )
        }
        var options = info.subtitleTracks.enumerated().map { position, track in
            let id = String(track.index)
            return PlayerTrackOption(
                id: id,
                label: trackLabel(track, fallback: "Subtitle \(position + 1)"),
                isSelected: selectedSubtitleID == id
            )
        }
        if let external = externalSubtitle {
            options.append(PlayerTrackOption(
                id: Self.externalTrackID,
                label: external.label,
                isSelected: selectedSubtitleID == Self.externalTrackID
            ))
        }
        textTrackOptions = options
    }

    private func publishVideoInfo(info: MediaInfo) {
        guard let track = info.videoTracks.first, let video = track.video else { return }
        videoInfo = PlayerVideoInfo(
            width: video.width,
            height: video.height,
            fps: video.fps,
            codec: track.codecName
        )
    }

    private func trackLabel(_ track: TrackInfo, fallback: String) -> String {
        if let title = track.title, !title.isEmpty {
            return title
        }
        if let language = track.language, !language.isEmpty {
            return TrackLanguageMatcher.displayName(for: language)
        }
        return fallback
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        if !hasStartedPlayback {
            PlaybackQoE.shared.noteStartupFailure()
        }
        onPlaybackFailure?()
    }

    private func sessionPositionSnapshot(_ session: PlayerSession) -> TimeInterval {
        let now = session.renderer.currentTime
        guard let info = mediaInfo, now != .min else { return 0 }
        return max(0, MediaTime.seconds(now - info.startTime))
    }
}

// MARK: - External subtitles

extension LumeEngineCoordinator: ExternalSubtitleLoading {
    /// Id for the sidecar track in the overlay's subtitle menu. Prefixed so it
    /// can never collide with an embedded track's stream index.
    static var externalTrackID: String {
        "external"
    }

    func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
        externalSubtitle = subtitle
        selectedSubtitleID = Self.externalTrackID
        loadExternalSubtitleFile(subtitle)
    }

    /// Hands the file to the engine, which parses it in full and replaces
    /// whatever subtitle lane was active. On failure the track is dropped from
    /// the menu rather than left selected but silent.
    private func loadExternalSubtitleFile(_ subtitle: ExternalSubtitle) {
        subtitleCues.update(nil)
        if let info = mediaInfo {
            publishTracks(info: info)
        }
        let session = session
        Task {
            do {
                try await session?.loadExternalSubtitles(url: subtitle.fileURL.absoluteString)
            } catch {
                Logger.player.error("LumeEngine could not load external subtitles: \(LogRedaction.describe(error), privacy: .public)")
                self.externalSubtitle = nil
                self.selectedSubtitleID = nil
                if let info = self.mediaInfo {
                    self.publishTracks(info: info)
                }
            }
        }
    }
}

#if os(tvOS)
    /// The shared Apple TV overlay drives LumeEngine through the same surface
    /// as every other engine. All requirements already exist with matching
    /// signatures, so the conformance is empty.
    extension LumeEngineCoordinator: TVPlaybackEngine {}
#endif
