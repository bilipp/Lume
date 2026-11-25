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
    /// Scales SDR 1080p to the display with Lanczos-3, on the software path.
    public var upscalesFullHDVideo: Bool
    /// What a 10-bit stream without any colour description is shown as:
    /// "hdr10" or "hlg"; anything else keeps the engine's reading (SDR).
    public var untaggedVideoColor: String
    public var audioDelaySeconds: Double
    public var prepareNativeSubtitles: Bool
    /// Reads bitmap cues with on-device text recognition and republishes
    /// them with `LumeAetherSubtitleImage.recognizedText`.
    public var recognizesBitmapSubtitleText: Bool
    /// How many requests the engine may have open against the source's
    /// origin at once; nil leaves it uncapped. The engine keeps a ceiling
    /// per origin for the rest of the process.
    public var maxConcurrentSourceRequests: Int?
    /// Extra seconds a fastZap live join may wait for a deeper first window;
    /// nil serves as soon as the minimum media exists (the engine default).
    public var liveStartupGraceSeconds: Double?
    /// Bytes of already-played and prefetched VOD segments the engine may
    /// keep in `tmp/` beyond its playback window; nil keeps the engine's
    /// own sizing (2 GiB, or a quarter of the free space when that is
    /// less). The engine ignores it for live.
    public var sessionCacheByteBudget: Int?
    /// The engine writes the display criteria (the TV switches to the
    /// video's frame rate and dynamic range, where tvOS Match Content
    /// allows it). False leaves the TV in the output format chosen in
    /// tvOS Settings: the engine writes nothing and only clears criteria
    /// it left applied itself.
    public var writesDisplayCriteria: Bool
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
        upscalesFullHDVideo: Bool,
        untaggedVideoColor: String,
        audioDelaySeconds: Double,
        prepareNativeSubtitles: Bool,
        recognizesBitmapSubtitleText: Bool,
        maxConcurrentSourceRequests: Int?,
        liveStartupGraceSeconds: Double?,
        sessionCacheByteBudget: Int?,
        writesDisplayCriteria: Bool,
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
        self.upscalesFullHDVideo = upscalesFullHDVideo
        self.untaggedVideoColor = untaggedVideoColor
        self.audioDelaySeconds = audioDelaySeconds
        self.prepareNativeSubtitles = prepareNativeSubtitles
        self.recognizesBitmapSubtitleText = recognizesBitmapSubtitleText
        self.maxConcurrentSourceRequests = maxConcurrentSourceRequests
        self.liveStartupGraceSeconds = liveStartupGraceSeconds
        self.sessionCacheByteBudget = sessionCacheByteBudget
        self.writesDisplayCriteria = writesDisplayCriteria
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

/// The source's dynamic range as the stream carries it, before any panel
/// clamping: a DV title on an SDR screen still reads `.dolbyVision`.
public nonisolated enum LumeAetherDynamicRange: Sendable, Equatable {
    case sdr
    case hdr10
    case hdr10Plus
    case hlg
    case dolbyVision
}

/// The layer Picture in Picture is built around, per route.
@frozen public enum LumeAetherPictureInPictureSource {
    /// The native path (loopback or remote HLS): `AVPlayerLayer` PiP.
    case player(AVPlayerLayer)
    /// The software path: sample-buffer PiP, transport answered by the
    /// session's `pictureInPicture…` members.
    case sampleBuffer(AVSampleBufferDisplayLayer)
}

/// A bitmap subtitle (PGS, DVB, DVD) showing now, fully rendered with
/// premultiplied alpha. `position` is normalized to [0, 1] against the
/// subtitle canvas; `canvasSize` is that canvas in pixels, `.zero` when the
/// source didn't name one (the canvas is then the video frame).
public nonisolated struct LumeAetherSubtitleImage: @unchecked Sendable, Equatable, Identifiable {
    /// Unique per cue within a session.
    public let id: Int
    public let image: CGImage
    public let position: CGRect
    public let canvasSize: CGSize
    /// The cue's lines as on-device text recognition read them, top first.
    /// Nil until the cue was read, when nothing readable was found, and
    /// whenever the load didn't ask for it.
    public let recognizedText: String?
    /// The lowest confidence among those lines, 0...1. The recognizer answers
    /// a few fixed grades, not a probability.
    public let recognizedTextConfidence: Float?

    public init(
        id: Int,
        image: CGImage,
        position: CGRect,
        canvasSize: CGSize,
        recognizedText: String? = nil,
        recognizedTextConfidence: Float? = nil
    ) {
        self.id = id
        self.image = image
        self.position = position
        self.canvasSize = canvasSize
        self.recognizedText = recognizedText
        self.recognizedTextConfidence = recognizedTextConfidence
    }

    /// Cue identity, never the pixels: a cue's image doesn't change. Its
    /// text does, once: the engine republishes a cue after reading it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.position == rhs.position && lhs.canvasSize == rhs.canvasSize
            && lhs.recognizedText == rhs.recognizedText
            && lhs.recognizedTextConfidence == rhs.recognizedTextConfidence
    }
}
