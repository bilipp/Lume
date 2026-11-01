#if !os(visionOS)

    import Combine
    import Foundation
    import LumeAetherBridge
    import OSLog
    import SwiftUI

    /// Playback surface for the AetherEngine backend.
    ///
    /// Owns one engine (`LumeAetherSession`) for its whole life and loads each
    /// stream into it; a load replaces the previous session on the same engine.
    /// Mirrors the coordinator surface of `LumeEngineCoordinator` so overlays
    /// stay engine-agnostic. Reconnects, engine fallback, overlays and Now
    /// Playing stay Lume's: the engine only reports.
    @MainActor
    final class AetherEngineCoordinator: NSObject, ObservableObject {
        @Published private(set) var isPlaying = false
        @Published private(set) var isBuffering = false
        /// Set once the picture is moving; drives the loading indicator and
        /// the startup-failure watchdog.
        @Published private(set) var hasStartedPlayback = false
        @Published private(set) var videoInfo: PlayerVideoInfo?
        @Published private(set) var audioTrackOptions: [PlayerTrackOption] = []
        @Published private(set) var textTrackOptions: [PlayerTrackOption] = []
        @Published private(set) var isPipActive = false
        /// Follows the route: the PiP layer comes and goes with the session.
        @Published private(set) var isPipSupported = false
        /// Active subtitle cue text, on its own observable so a cue change
        /// invalidates only the subtitle leaf, never every overlay observing
        /// this coordinator (see `LumeEngineCoordinator.subtitleCues`).
        let subtitleCues = SubtitleCueModel()

        var playbackRate: Float = 1.0 {
            didSet { session?.setRate(playbackRate) }
        }

        /// The engine's playback tick: (current, duration) in seconds. A
        /// callback rather than `@Published`, so the host writes it into its
        /// `PlaybackClock` and nothing observing this coordinator re-renders.
        var onTime: ((TimeInterval, TimeInterval) -> Void)?
        /// Initial-load failure (hard error or startup timeout before the
        /// picture moved), with its cause.
        var onPlaybackFailure: ((AetherEngineFailure) -> Void)?
        /// The PiP window went away, so the host can end the session if the
        /// user closed it rather than restoring the player.
        var onPictureInPictureStop: (() -> Void)?
        /// Mid-stream drop after playback had started, with its cause; the
        /// view routes this through `PlaybackRetryController`.
        var onStalled: ((AetherEngineFailure) -> Void)?
        /// Playback reached a healthy playing state — the view resets its
        /// reconnect budget.
        var onRecovered: (() -> Void)?
        /// The FFmpeg codec names of the audio tracks, whenever the set changes.
        var onAudioCodecs: (([String]) -> Void)?

        /// Set before `configure` for a Multiview tile or a guide preview:
        /// secondary output role, no display criteria, no Picture in Picture.
        /// The host sets `isMuted` and `startupTimeout` itself.
        var isEmbedded = false
        /// The startup-failure window for each load, set by the host before
        /// `configure`.
        var startupTimeout = AetherEngineCoordinator.defaultStartupTimeout
        static let defaultStartupTimeout: TimeInterval = 40
        /// Gives up early so the next engine gets its turn sooner.
        static let quickStartupTimeout: TimeInterval = 15

        /// Silences this player without pausing it. Every engine keeps
        /// decoding its audio, so switching the audible tile is a volume
        /// change, not a reload.
        var isMuted = false {
            didSet {
                guard isMuted != oldValue else { return }
                applyAudioLevel()
            }
        }

        /// The full-screen player's volume; every load inherits it. Written
        /// only through `applyUserVolume`.
        var userVolume: Float = 1

        /// The engine's video surface for the hosting representable; nil until
        /// the first `configure`.
        var videoView: LumeAetherPlatformView? {
            session?.videoView
        }

        /// Published so the hosting surface re-renders and installs the
        /// engine's view once the first `configure` builds the session; the
        /// native route never reaches readiness without a layer in a window.
        @Published private(set) var session: LumeAetherSession?
        var pictureInPicture: AetherPictureInPictureController?
        private var currentMedia: PlayableMedia?
        private var loadTask: Task<Void, Never>?
        /// Bumped by every load and teardown, so a late result from a
        /// superseded load is dropped.
        private var loadGeneration = 0
        var startupTask: Task<Void, Never>?
        /// Set once this load has been reported as failed; see `streamFailed`.
        var reportedFailure = false
        /// Whether this stream played in an earlier load. A reconnect that
        /// fails before its first frame is still a drop of a stream that
        /// played, so it goes back through the reconnect budget rather than
        /// the startup-failure path. Survives `reload`, cleared by `configure`.
        private(set) var hasPlayedStream = false
        /// An audio track picked by hand, carried into a reload (a fresh load)
        /// so it outranks the preferred languages. Cleared when the URL
        /// changes. Persisted nowhere.
        private var manualAudioTrackID: Int?
        /// The sidecar subtitle file loaded from the OpenSubtitles search. A
        /// load forgets runtime tracks, so it is listed again after each one.
        private var externalSubtitle: ExternalSubtitle?
        private var externalSubtitleTrackID: Int?
        private var isExternalSubtitleSelected = false
        /// The audio codecs last reported, so a republish of the same tracks
        /// doesn't report them again. Cleared by `configure`: the host resets
        /// its codecs when it swaps streams.
        private var loggedAudioCodecs: String?

        // MARK: Lifecycle

        func configure(media: PlayableMedia) {
            if media.url != currentMedia?.url {
                manualAudioTrackID = nil
            }
            hasPlayedStream = false
            loggedAudioCodecs = nil
            start(media)
        }

        /// Fresh load of the same stream (stall recovery), resuming from the
        /// current position for VOD. `url` swaps in a freshly resolved stream
        /// URL without counting as a new stream, so a manual track pick
        /// survives it.
        func reload(replacingURL url: URL? = nil) {
            guard var media = currentMedia else { return }
            if let url {
                media = media.replacingURL(url)
            }
            if media.kind == .vod, let session, session.currentTime > 0 {
                media = media.resuming(at: session.currentTime)
            }
            start(media)
        }

        private func start(_ media: PlayableMedia) {
            // A window that is up survives the reload: the next load replaces
            // the running one in place, and a native session hands its item
            // over without closing the window.
            endLoad(stopsSession: !isPipActive)
            currentMedia = media
            reportedFailure = false
            // After `tearDown` (which ends any previous session) so a reload
            // counts as its own startup attempt rather than extending the last.
            PlaybackQoE.shared.beginStartup(engine: .aetherEngine, isLive: media.isLive)

            let session: LumeAetherSession
            do {
                session = try engineSession()
            } catch {
                Logger.player.error("AetherEngine could not start: \(LogRedaction.describe(error), privacy: .public)")
                streamFailed(.unsupported)
                return
            }
            let plan = AetherLoadPlan.make(options: .load(), context: loadContext(for: media))
            applyAudioLevel()
            startupTask = makeStartupWatchdog(timeout: startupTimeout)

            let request = LumeAetherLoadRequest(plan: plan, media: media, audioStreamIndex: manualAudioTrackID)
            let generation = loadGeneration
            loadTask = Task {
                do {
                    try await session.load(request)
                    guard generation == self.loadGeneration else { return }
                    self.restoreExternalSubtitle(on: session)
                    if self.playbackRate != 1 {
                        session.setRate(self.playbackRate)
                    }
                    if !self.isEmbedded {
                        if let pictureInPicture = self.pictureInPicture {
                            pictureInPicture.refresh()
                        } else {
                            self.pictureInPicture = self.makePictureInPicture(for: session)
                        }
                    }
                    self.publishMedia()
                } catch is CancellationError {
                    // A newer load or a teardown superseded this one.
                    return
                } catch {
                    guard generation == self.loadGeneration else { return }
                    self.engineFailed(error as? LumeAetherFailure)
                }
            }
        }

        /// Ends the session. The engine stays for the next `configure`, so a
        /// stopped coordinator holds no source connection, audio session or
        /// display criteria.
        func tearDown() {
            pictureInPicture?.stop()
            endLoad(stopsSession: true)
        }

        private func endLoad(stopsSession: Bool) {
            PlaybackQoE.shared.endSession()
            loadGeneration += 1
            loadTask?.cancel()
            startupTask?.cancel()
            loadTask = nil
            startupTask = nil
            if stopsSession {
                session?.stop()
            }
            isPlaying = false
            isBuffering = false
            hasStartedPlayback = false
            subtitleCues.update(nil)
            externalSubtitleTrackID = nil
        }

        // MARK: Transport

        func togglePlay() {
            if isPlaying {
                session?.pause()
            } else {
                session?.play()
            }
        }

        func skip(by seconds: Double) {
            guard let session else { return }
            seek(to: max(0, session.currentTime + seconds))
        }

        func seek(to seconds: TimeInterval) {
            let session = session
            Task { await session?.seek(to: seconds) }
        }

        func togglePictureInPicture() {
            pictureInPicture?.toggle()
        }

        // MARK: Tracks

        func selectAudioTrack(id: String) {
            guard let index = Int(id) else { return }
            manualAudioTrackID = index
            session?.selectAudioTrack(id: index)
        }

        func selectTextTrack(id: String?) {
            let index = id.flatMap(Int.init)
            isExternalSubtitleSelected = index != nil && index == externalSubtitleTrackID
            session?.selectSubtitleTrack(id: index)
            if index == nil {
                subtitleCues.update(nil)
            }
        }

        // MARK: Internals

        /// The engine, built on first use and kept for every later load.
        private func engineSession() throws -> LumeAetherSession {
            if let session {
                return session
            }
            let session = try LumeAetherSession()
            session.onTime = { [weak self] current, duration in
                self?.onTime?(current, duration)
            }
            session.onPhaseChange = { [weak self] phase in
                self?.handle(phase: phase)
            }
            session.onFailure = { [weak self] failure in
                self?.engineFailed(failure)
            }
            session.onLiveSourceReset = { [weak self] in
                Logger.player.warning("AetherEngine live source reset → retune")
                self?.streamFailed(.sourceEnded)
            }
            session.onAudioDropped = { [weak self] in
                Logger.player.error("AetherEngine dropped the audio: no pipeline for the source's audio")
                self?.streamFailed(.unsupported)
            }
            session.onMediaChange = { [weak self] in
                self?.publishMedia()
            }
            session.onSubtitleText = { [weak self] text in
                self?.subtitleCues.update(text)
            }
            self.session = session
            return session
        }

        private func loadContext(for media: PlayableMedia) -> AetherLoadContext {
            AetherLoadContext(
                isLive: media.isLive,
                httpHeaders: media.httpHeaders,
                preferredAudioLanguages: PlayerLanguageOptions.load().preferredAudioLanguages,
                isEmbedded: isEmbedded
            )
        }

        private func handle(phase: LumeAetherPhase) {
            let label = String(describing: phase)
            Logger.player.info("AetherEngine phase → \(label, privacy: .public)")
            pictureInPicture?.refresh()
            pictureInPicture?.invalidatePlaybackState()
            switch phase {
            case .playing:
                isPlaying = true
                isBuffering = false
                PlaybackQoE.shared.noteStallEnded()
                if !hasStartedPlayback {
                    hasStartedPlayback = true
                    hasPlayedStream = true
                    startupTask?.cancel()
                    PlaybackQoE.shared.noteFirstFrame()
                }
                onRecovered?()
            case .paused, .idle:
                resetTransportFlags()
                PlaybackQoE.shared.noteStallEnded()
            case .loading, .seeking:
                isBuffering = true
            case .rebuffering, .stalled:
                isBuffering = true
                if hasStartedPlayback {
                    PlaybackQoE.shared.noteStallBegan()
                }
            case .ended:
                resetTransportFlags()
                // `.ended` is terminal: nothing revives it but a new load. A
                // live channel that ends is a lost source.
                if currentMedia?.isLive == true {
                    streamFailed(.sourceEnded)
                }
            case .failed:
                // Reported with its cause through `onFailure`.
                resetTransportFlags()
            }
        }

        private func resetTransportFlags() {
            isPlaying = false
            isBuffering = false
        }

        func publishMedia() {
            guard let session else { return }
            let audio = session.audioTracks
            reportAudioCodecs(audio)
            let audioOptions = audio.enumerated().map { position, track in
                PlayerTrackOption(
                    id: String(track.id),
                    label: trackLabel(track, fallback: "Audio \(position + 1)"),
                    isSelected: session.activeAudioTrackID.map { $0 == track.id } ?? (position == 0)
                )
            }
            let textOptions = session.subtitleTracks.enumerated().map { position, track in
                PlayerTrackOption(
                    id: String(track.id),
                    label: track.isExternal && track.id == externalSubtitleTrackID
                        ? externalSubtitle?.label ?? track.name
                        : trackLabel(track, fallback: "Subtitle \(position + 1)"),
                    isSelected: session.activeSubtitleTrackID == track.id
                )
            }
            if audioOptions != audioTrackOptions {
                audioTrackOptions = audioOptions
            }
            if textOptions != textTrackOptions {
                textTrackOptions = textOptions
            }
            if let info = session.videoInfo {
                let published = PlayerVideoInfo(width: info.width, height: info.height, fps: info.frameRate ?? 0, codec: info.codec)
                if published != videoInfo {
                    videoInfo = published
                }
            }
        }

        private func makePictureInPicture(for session: LumeAetherSession) -> AetherPictureInPictureController {
            let controller = AetherPictureInPictureController(session: session)
            controller.onActiveChange = { [weak self] active in
                self?.isPipActive = active
            }
            controller.onStop = { [weak self] in
                self?.onPictureInPictureStop?()
            }
            controller.onSupportChange = { [weak self] supported in
                self?.isPipSupported = supported
            }
            isPipSupported = controller.isSupported
            return controller
        }

        private func trackLabel(_ track: LumeAetherTrack, fallback: String) -> String {
            if !track.name.isEmpty {
                return track.name
            }
            if let language = track.language, !language.isEmpty {
                return TrackLanguageMatcher.displayName(for: language)
            }
            return fallback
        }

        /// Hands the tracks' codecs to `onAudioCodecs` and logs them, once per
        /// set: a Cast receiver plays only some of them.
        private func reportAudioCodecs(_ tracks: [LumeAetherTrack]) {
            let codecs = tracks.map { "\($0.codec) \($0.channels)ch \($0.sampleRate)Hz" }.joined(separator: " | ")
            guard codecs != loggedAudioCodecs else { return }
            loggedAudioCodecs = codecs
            onAudioCodecs?(tracks.map(\.codec))
            Logger.player.notice("AetherEngine audio tracks: \(codecs, privacy: .public)")
        }

        private func restoreExternalSubtitle(on session: LumeAetherSession) {
            guard let externalSubtitle else { return }
            let id = session.addExternalSubtitle(fileURL: externalSubtitle.fileURL, name: externalSubtitle.label)
            externalSubtitleTrackID = id
            if isExternalSubtitleSelected {
                session.selectSubtitleTrack(id: id)
            }
        }
    }

    // MARK: - External subtitles

    extension AetherEngineCoordinator: ExternalSubtitleLoading {
        func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
            externalSubtitle = subtitle
            isExternalSubtitleSelected = true
            subtitleCues.update(nil)
            guard let session else { return }
            restoreExternalSubtitle(on: session)
            publishMedia()
        }
    }

    // MARK: - Load request

    extension LumeAetherLoadRequest {
        /// The bridge's request for `plan`. A VOD resume starts at the saved
        /// position; live always joins at the edge.
        init(plan: AetherLoadPlan, media: PlayableMedia, audioStreamIndex: Int?) {
            self.init(
                url: media.url,
                startPosition: !media.isLive && media.startTime > 1 ? media.startTime : nil,
                audioStreamIndex: audioStreamIndex.flatMap { Int32(exactly: $0) },
                httpHeaders: plan.httpHeaders,
                isLive: plan.isLive,
                preferredAudioLanguages: audioStreamIndex == nil ? plan.preferredAudioLanguages : [],
                preferredDecodePath: plan.preferredDecodePath.rawValue,
                escalatesToSoftwarePath: plan.escalatesToSoftwarePath,
                deinterlaceMode: plan.deinterlaceMode.rawValue,
                deinterlaceFieldRate: plan.deinterlaceFieldRate.rawValue,
                usesFastZapLiveJoin: plan.liveJoinProfile == .fastZap,
                forwardBufferSegments: plan.forwardBufferSegments,
                probesize: plan.probesize,
                maxAnalyzeDuration: plan.maxAnalyzeDuration,
                nativeRemoteHLS: plan.nativeRemoteHLS,
                audioBridgeMode: plan.audioBridgeMode.rawValue,
                dolbyVisionHandling: plan.dolbyVisionHandling.rawValue,
                upscalesLowResolutionVideo: plan.upscalesLowResolutionVideo,
                audioDelaySeconds: plan.audioDelaySeconds,
                prepareNativeSubtitles: plan.prepareNativeSubtitles,
                matchContentEnabled: plan.matchContentEnabled,
                isSecondaryOutput: plan.sharedOutputRole == .secondary
            )
        }
    }

    #if os(tvOS)
        /// The shared Apple TV overlay drives AetherEngine through the same
        /// surface as every other engine; every requirement already exists.
        extension AetherEngineCoordinator: TVPlaybackEngine {}
    #endif

#endif
