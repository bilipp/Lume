import AVFoundation
import Foundation

/// What a load hands the engine, in plain values. Enum-shaped fields carry the
/// engine's own raw values; an unknown one keeps the engine default.
public nonisolated struct LumeAetherLoadRequest: Sendable, Equatable {
    public var url: URL
    /// Source-axis seconds, or nil to start at the beginning (VOD) or the edge (live).
    public var startPosition: Double?
    /// Stream index of an audio track picked by hand, which outranks
    /// `preferredAudioLanguages`.
    public var audioStreamIndex: Int32?
    public var httpHeaders: [String: String]
    public var isLive: Bool
    public var preferredAudioLanguages: [String]
    public var preferredDecodePath: String
    public var escalatesToSoftwarePath: Bool
    public var deinterlaceMode: String
    public var deinterlaceFieldRate: String
    public var usesFastZapLiveJoin: Bool
    public var forwardBufferSegments: Int?
    public var probesize: Int64?
    public var maxAnalyzeDuration: Int64?
    public var nativeRemoteHLS: Bool
    public var audioBridgeMode: String
    public var dolbyVisionHandling: String
    public var upscalesLowResolutionVideo: Bool
    public var audioDelaySeconds: Double
    public var prepareNativeSubtitles: Bool
    public var matchContentEnabled: Bool
    /// A Multiview tile or a guide preview: never writes display criteria and
    /// never owns Now Playing.
    public var isSecondaryOutput: Bool

    public init(
        url: URL,
        startPosition: Double?,
        audioStreamIndex: Int32?,
        httpHeaders: [String: String],
        isLive: Bool,
        preferredAudioLanguages: [String],
        preferredDecodePath: String,
        escalatesToSoftwarePath: Bool,
        deinterlaceMode: String,
        deinterlaceFieldRate: String,
        usesFastZapLiveJoin: Bool,
        forwardBufferSegments: Int?,
        probesize: Int64?,
        maxAnalyzeDuration: Int64?,
        nativeRemoteHLS: Bool,
        audioBridgeMode: String,
        dolbyVisionHandling: String,
        upscalesLowResolutionVideo: Bool,
        audioDelaySeconds: Double,
        prepareNativeSubtitles: Bool,
        matchContentEnabled: Bool,
        isSecondaryOutput: Bool
    ) {
        self.url = url
        self.startPosition = startPosition
        self.audioStreamIndex = audioStreamIndex
        self.httpHeaders = httpHeaders
        self.isLive = isLive
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredDecodePath = preferredDecodePath
        self.escalatesToSoftwarePath = escalatesToSoftwarePath
        self.deinterlaceMode = deinterlaceMode
        self.deinterlaceFieldRate = deinterlaceFieldRate
        self.usesFastZapLiveJoin = usesFastZapLiveJoin
        self.forwardBufferSegments = forwardBufferSegments
        self.probesize = probesize
        self.maxAnalyzeDuration = maxAnalyzeDuration
        self.nativeRemoteHLS = nativeRemoteHLS
        self.audioBridgeMode = audioBridgeMode
        self.dolbyVisionHandling = dolbyVisionHandling
        self.upscalesLowResolutionVideo = upscalesLowResolutionVideo
        self.audioDelaySeconds = audioDelaySeconds
        self.prepareNativeSubtitles = prepareNativeSubtitles
        self.matchContentEnabled = matchContentEnabled
        self.isSecondaryOutput = isSecondaryOutput
    }
}

/// The engine's playback phase: transport intent folded with motion, so
/// `.playing` means the picture is moving.
@frozen public nonisolated enum LumeAetherPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case failed
}

/// A failure the engine reported, in its stable machine-readable form. The
/// message is the engine's (or the OS's localized) text, for logs only.
public nonisolated struct LumeAetherFailure: Error, Sendable, Equatable {
    /// `PlaybackErrorKind.rawValue`; stable across releases and locales.
    public let kind: String
    /// The HTTP status for a refusal, else the underlying `NSError` code.
    public let underlyingCode: Int?
    public let message: String

    public init(kind: String, underlyingCode: Int?, message: String) {
        self.kind = kind
        self.underlyingCode = underlyingCode
        self.message = message
    }
}

public nonisolated struct LumeAetherTrack: Sendable, Equatable, Identifiable {
    /// The engine's track id: a stream index, or a synthetic id for external
    /// and remote-HLS tracks.
    public let id: Int
    public let name: String
    public let codec: String
    public let language: String?
    public let channels: Int
    public let sampleRate: Int
    public let isDefault: Bool
    public let isForced: Bool
    public let isExternal: Bool

    public init(
        id: Int,
        name: String,
        codec: String,
        language: String?,
        channels: Int,
        sampleRate: Int,
        isDefault: Bool,
        isForced: Bool,
        isExternal: Bool
    ) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.sampleRate = sampleRate
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
    }
}

public nonisolated struct LumeAetherVideoInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double?
    public let codec: String?

    public init(width: Int, height: Int, frameRate: Double?, codec: String?) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
    }
}

/// The layer Picture in Picture is built around, per route.
@frozen public enum LumeAetherPictureInPictureSource {
    /// The native path (loopback or remote HLS): `AVPlayerLayer` PiP.
    case player(AVPlayerLayer)
    /// The software path: sample-buffer PiP, transport answered by the
    /// session's `pictureInPicture…` members.
    case sampleBuffer(AVSampleBufferDisplayLayer)
}
