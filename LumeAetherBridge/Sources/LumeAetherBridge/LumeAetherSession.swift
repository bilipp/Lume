internal import AetherEngine
import AVFoundation
import Combine
import Foundation

#if canImport(UIKit)
    import UIKit

    public typealias LumeAetherPlatformView = UIView
#elseif canImport(AppKit)
    import AppKit

    public typealias LumeAetherPlatformView = NSView
#endif

/// One AetherEngine for one playback surface, behind a Lume-facing API made
/// of plain values. Loads replace each other on the same engine; the host
/// owns retries, fallback, overlays and Now Playing.
public final class LumeAetherSession {
    /// The 10 Hz playback tick: current position and duration, in seconds.
    public var onTime: ((Double, Double) -> Void)?
    public var onPhaseChange: ((LumeAetherPhase) -> Void)?
    /// The session failed after `load` returned, or while it ran. A load that
    /// throws reports the same failure here too.
    public var onFailure: ((LumeAetherFailure) -> Void)?
    /// A live session the engine cannot revive asks the host to retune.
    public var onLiveSourceReset: (() -> Void)?
    /// The source has audio and none of it reaches the output.
    public var onAudioDropped: (() -> Void)?
    /// Tracks, the active selections or the video description changed.
    public var onMediaChange: (() -> Void)?
    /// The text of the subtitle cues showing now, nil when none is.
    public var onSubtitleText: ((String?) -> Void)?
    /// The route serving the session changed, so `pictureInPictureSource`
    /// may name another layer.
    public var onPictureInPictureSourceChange: (() -> Void)?

    private let engine: AetherEngine
    private let playerView: AetherPlayerView
    private var cancellables: Set<AnyCancellable> = []
    private var lastSubtitleText: String?
    /// The source-time span over which the showing cues stay the same, and
    /// their text, so a tick inside it skips scanning every cue.
    private var subtitleCueWindow: (span: Range<Double>, text: String?)?
    private var isMediaChangePending = false

    public init() throws {
        engine = try AetherEngine()
        #if os(iOS) || os(tvOS)
            engine.ownsVideoNowPlayingSession = false
        #endif
        engine.ownsSoftwareNowPlaying = false
        playerView = AetherPlayerView(frame: .zero)
        engine.bind(view: playerView)
        observe()
    }

    /// The view the engine presents into, whichever layer the route needs.
    public var videoView: LumeAetherPlatformView {
        playerView
    }

    // MARK: Loading

    /// Replaces whatever this engine was playing. Throws `CancellationError`
    /// when a newer load or a `stop()` superseded this one, else a
    /// `LumeAetherFailure`.
    public func load(_ request: LumeAetherLoadRequest) async throws {
        do {
            try await engine.load(
                url: request.url,
                startPosition: request.startPosition,
                options: Self.loadOptions(for: request),
                audioSourceStreamIndex: request.audioStreamIndex
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(for: error)
        }
    }

    /// Ends the session and releases its shared outputs (audio session,
    /// display criteria). Call it before letting go of the session.
    public func stop() {
        engine.stop()
        publishSubtitleText(nil)
    }

    // MARK: Transport

    public func play() {
        engine.play()
    }

    public func pause() {
        engine.pause()
    }

    public func seek(to seconds: Double) async {
        await engine.seek(to: seconds)
    }

    public func setRate(_ rate: Float) {
        engine.setRate(rate)
    }

    /// 0...1; remembered before a session exists and applied at load.
    public var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }

    public var currentTime: Double {
        engine.clock.currentTime
    }

    public var isLive: Bool {
        engine.isLive
    }

    /// Startup work finished so far for the current load, 0 before any.
    public var startupCheckpointsCompleted: Int {
        engine.startupProgress?.completed ?? 0
    }

    // MARK: Media

    public var audioTracks: [LumeAetherTrack] {
        engine.audioTracks.map(Self.track)
    }

    public var subtitleTracks: [LumeAetherTrack] {
        engine.subtitleTracks.map(Self.track)
    }

    public var activeAudioTrackID: Int? {
        engine.activeAudioTrackIndex
    }

    public var activeSubtitleTrackID: Int? {
        engine.activeSubtitleTrackIndex
    }

    public var videoInfo: LumeAetherVideoInfo? {
        guard engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return nil }
        return LumeAetherVideoInfo(
            width: Int(engine.sourceVideoWidth),
            height: Int(engine.sourceVideoHeight),
            frameRate: engine.sourceVideoFrameRate,
            codec: engine.sourceVideoCodecName
        )
    }

    public func selectAudioTrack(id: Int) {
        engine.selectAudioTrack(index: id)
    }

    /// nil turns subtitles off.
    public func selectSubtitleTrack(id: Int?) {
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
            publishSubtitleText(nil)
        }
    }

    /// Lists a local subtitle file as a track and returns its id. A load
    /// forgets it, so it is added again after each one.
    public func addExternalSubtitle(fileURL: URL, name: String) -> Int {
        engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: fileURL, name: name)).id
    }

    // MARK: Picture in Picture

    /// The layer a Picture in Picture controller is built around for the
    /// route serving now: the software path's display layer, else the native
    /// path's player layer. Read it again after `onPictureInPictureSourceChange`
    /// and after each load; a fresh session can bring a fresh layer.
    public var pictureInPictureSource: LumeAetherPictureInPictureSource? {
        if let source = engine.softwarePiPSource {
            return .sampleBuffer(source.layer)
        }
        if let layer = engine.nativePlayerLayer {
            return .player(layer)
        }
        return nil
    }

    /// Set from the PiP controller's delegate, at *will* start: it keeps the
    /// pipeline alive across the background transition (tvOS tears down
    /// otherwise), keeps the software path decoding video, draws subtitles
    /// into the window's frames there and hands them to AVKit on the native
    /// path.
    public var isPictureInPictureActive: Bool {
        get { engine.pictureInPictureActive }
        set {
            guard newValue != engine.pictureInPictureActive else { return }
            engine.pictureInPictureActive = newValue
            if engine.nativePlayerLayer != nil {
                engine.setNativeSubtitleRendering(newValue)
            }
        }
    }

    /// Sample-buffer PiP's playable range, on the enqueued frames' axis.
    /// Indefinite for live, so the window shows its live controls.
    public func pictureInPictureTimeRange() -> CMTimeRange {
        engine.softwarePiPSource?.timeRange()
            ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public var isPictureInPicturePaused: Bool {
        engine.softwarePiPSource?.isPaused ?? true
    }

    public func setPictureInPicturePlaying(_ playing: Bool) {
        engine.softwarePiPSource?.setPlaying(playing)
    }

    public func skipPictureInPicture(by seconds: Double) {
        engine.softwarePiPSource?.skip(by: seconds)
    }

    // MARK: Internals

    private func observe() {
        engine.clock.$currentTime
            .sink { [weak self] current in
                guard let self else { return }
                onTime?(current, engine.duration)
                publishSubtitleText(activeSubtitleText())
            }
            .store(in: &cancellables)
        engine.$playbackPhase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.onPhaseChange?(Self.phase(phase))
            }
            .store(in: &cancellables)
        engine.$state
            .sink { [weak self] state in
                guard let self, case let .error(message) = state else { return }
                onFailure?(failure(message: message))
            }
            .store(in: &cancellables)
        Publishers.Merge(
            engine.$softwarePiPSource.map { _ in () }.eraseToAnyPublisher(),
            engine.$videoRoute.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        // `@Published` emits before the property changes; read after it has.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.onPictureInPictureSourceChange?() }
        .store(in: &cancellables)
        engine.liveSourceReset
            .sink { [weak self] in self?.onLiveSourceReset?() }
            .store(in: &cancellables)
        engine.$audioDelivery
            .removeDuplicates()
            .filter { $0 == .droppedNoPipeline }
            .sink { [weak self] _ in self?.onAudioDropped?() }
            .store(in: &cancellables)
        Publishers.MergeMany(
            engine.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            engine.$subtitleTracks.map { _ in () }.eraseToAnyPublisher(),
            engine.$activeAudioTrackIndex.map { _ in () }.eraseToAnyPublisher(),
            engine.$activeSubtitleTrackIndex.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoWidth.map { _ in () }.eraseToAnyPublisher(),
            engine.$sourceVideoCodecName.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.scheduleMediaChange() }
        .store(in: &cancellables)
        Publishers.Merge(
            engine.$subtitleCues.map { _ in () },
            engine.$isSubtitleActive.map { _ in () }
        )
        .sink { [weak self] in self?.subtitleCueWindow = nil }
        .store(in: &cancellables)
    }

    /// One load sets several of the observed properties in a row; they reach
    /// the host as one change. `@Published` emits before the property
    /// changes, so the host reads them on the next main-queue turn.
    private func scheduleMediaChange() {
        guard !isMediaChangePending else { return }
        isMediaChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isMediaChangePending = false
            onMediaChange?()
        }
    }

    private func activeSubtitleText() -> String? {
        guard engine.isSubtitleActive else { return nil }
        let now = engine.clock.sourceTime
        if let window = subtitleCueWindow, window.span.contains(now) {
            return window.text
        }
        var lower = -Double.infinity
        var upper = Double.infinity
        var lines: [String] = []
        for cue in engine.subtitleCues {
            if cue.startTime <= now, now < cue.endTime {
                lower = max(lower, cue.startTime)
                upper = min(upper, cue.endTime)
                if let text = cue.text, !text.isEmpty {
                    lines.append(text)
                }
            } else if cue.endTime <= now {
                lower = max(lower, cue.endTime)
            } else if cue.startTime > now {
                upper = min(upper, cue.startTime)
            }
        }
        let text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        subtitleCueWindow = lower <= upper ? (lower ..< upper, text) : nil
        return text
    }

    private func publishSubtitleText(_ text: String?) {
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        onSubtitleText?(text)
    }

    private func failure(message: String) -> LumeAetherFailure {
        LumeAetherFailure(
            kind: engine.errorInfo?.kind.rawValue ?? "",
            underlyingCode: engine.errorInfo?.underlyingCode,
            message: message
        )
    }

    private func failure(for error: Error) -> LumeAetherFailure {
        if let info = engine.errorInfo {
            return LumeAetherFailure(kind: info.kind.rawValue, underlyingCode: info.underlyingCode, message: info.message)
        }
        return LumeAetherFailure(kind: "", underlyingCode: nil, message: String(describing: error))
    }

    private static func phase(_ phase: PlaybackPhase) -> LumeAetherPhase {
        switch phase {
        case .idle: .idle
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        case .seeking: .seeking
        case .rebuffering: .rebuffering
        case let .stalled(reconnecting): .stalled(reconnecting: reconnecting)
        case .ended: .ended
        case .error: .failed
        }
    }

    private static func track(_ info: TrackInfo) -> LumeAetherTrack {
        LumeAetherTrack(
            id: info.id,
            name: info.name,
            codec: info.codec,
            language: info.language,
            channels: info.channels,
            sampleRate: info.sampleRate,
            isDefault: info.isDefault,
            isForced: info.isForced,
            isExternal: info.isExternal
        )
    }

    /// Fields the request does not carry keep the engine's defaults, and
    /// `dvrWindowSeconds` stays nil: Lume offers no timeshift on this engine.
    private static func loadOptions(for request: LumeAetherLoadRequest) -> LoadOptions {
        var options = LoadOptions(
            dolbyVisionHandling: DolbyVisionHandling(rawValue: request.dolbyVisionHandling) ?? .automatic,
            upscalesLowResolutionVideo: request.upscalesLowResolutionVideo,
            matchContentEnabled: request.matchContentEnabled,
            audioBridgeMode: AudioBridgeMode(rawValue: request.audioBridgeMode) ?? .surroundCompat,
            isLive: request.isLive,
            liveJoinProfile: request.usesFastZapLiveJoin ? .fastZap : .standard,
            nativeRemoteHLS: request.nativeRemoteHLS,
            prepareNativeSubtitles: request.prepareNativeSubtitles,
            probesize: request.probesize,
            maxAnalyzeDuration: request.maxAnalyzeDuration,
            preferredAudioLanguages: request.preferredAudioLanguages,
            forwardBufferSegments: request.forwardBufferSegments,
            audioDelaySeconds: request.audioDelaySeconds,
            deinterlaceMode: DeinterlaceMode(rawValue: request.deinterlaceMode) ?? .auto,
            deinterlaceFieldRate: DeinterlaceFieldRate(rawValue: request.deinterlaceFieldRate) ?? .field,
            preferredDecodePath: DecodePath(rawValue: request.preferredDecodePath) ?? .automatic,
            escalatesToSoftwarePath: request.escalatesToSoftwarePath,
            sharedOutputRole: request.isSecondaryOutput ? .secondary : .primary
        )
        options.httpHeaders = request.httpHeaders
        return options
    }
}
