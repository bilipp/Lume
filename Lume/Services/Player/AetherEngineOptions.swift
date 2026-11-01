//
//  AetherEngineOptions.swift
//  Lume
//
//  AetherEngine's curated option set: the pickable choices, the snapshot read
//  from `UserDefaults`, and the pure mapping onto the values a load hands the
//  engine. AetherEngine's own types stay behind `LumeAetherBridge`, so the
//  mapping produces `AetherLoadPlan`, whose raw values match the engine's
//  enums one-to-one. Diagnostic flags and the trait-gated options (object
//  audio rendering, dual-layer HDR) are deliberately absent.
//

import Foundation

// MARK: - Settings

extension PlayerSettings {
    /// Storage keys and defaults for AetherEngine's curated option set, read by
    /// `AetherEngineOptions.load(from:)`. Device-local, never synced. The
    /// defaults match `LoadOptions`' own, except native remote HLS (on) and
    /// Match Content (on; only honoured on tvOS).
    nonisolated enum Aether {
        static let decodePathKey = "player.aether.decodePath"
        static let escalateToSoftwareKey = "player.aether.escalateToSoftware"
        static let deinterlaceModeKey = "player.aether.deinterlaceMode"
        static let deinterlaceFieldRateKey = "player.aether.deinterlaceFieldRate"
        static let liveJoinProfileKey = "player.aether.liveJoinProfile"
        static let forwardBufferSegmentsKey = "player.aether.forwardBufferSegments"
        static let probeSizeKey = "player.aether.probeSize"
        static let analyzeDurationKey = "player.aether.analyzeDuration"
        static let nativeRemoteHLSKey = "player.aether.nativeRemoteHLS"
        static let audioBridgeModeKey = "player.aether.audioBridgeMode"
        static let dynamicRangeKey = "player.aether.dynamicRange"
        static let upscaleLowResolutionKey = "player.aether.upscaleLowResolution"
        static let audioDelayKey = "player.aether.audioDelay"
        static let prepareNativeSubtitlesKey = "player.aether.prepareNativeSubtitles"
        static let matchContentKey = "player.aether.matchContent"

        static let decodePathDefault = AetherDecodePath.automatic
        static let escalateToSoftwareDefault = true
        static let deinterlaceModeDefault = AetherDeinterlaceMode.auto
        static let deinterlaceFieldRateDefault = AetherDeinterlaceFieldRate.field
        static let liveJoinProfileDefault = AetherLiveJoinProfile.standard
        /// 0 keeps the engine's own window (10 segments, ~40 s).
        static let forwardBufferSegmentsDefault = 0
        static let probeSizeDefault = AetherProbeSize.auto
        static let analyzeDurationDefault = AetherAnalyzeDuration.auto
        static let nativeRemoteHLSDefault = true
        static let audioBridgeModeDefault = AetherAudioBridgeMode.surroundCompat
        static let dynamicRangeDefault = AetherDynamicRangeHandling.automatic
        static let upscaleLowResolutionDefault = false
        /// Audio presentation offset, in milliseconds; positive plays audio later.
        static let audioDelayDefault = 0
        static let prepareNativeSubtitlesDefault = false
        static let matchContentDefault = true

        /// Every persisted AetherEngine option key. Used to wipe the stored
        /// values so each `@AppStorage` binding reverts to its default.
        static var allKeys: [String] {
            [
                decodePathKey, escalateToSoftwareKey, deinterlaceModeKey,
                deinterlaceFieldRateKey, liveJoinProfileKey, forwardBufferSegmentsKey,
                probeSizeKey, analyzeDurationKey, nativeRemoteHLSKey,
                audioBridgeModeKey, dynamicRangeKey, upscaleLowResolutionKey,
                audioDelayKey, prepareNativeSubtitlesKey, matchContentKey
            ]
        }

        /// Clear every stored AetherEngine option so the engine and its
        /// settings UI fall back to the built-in defaults.
        static func resetToDefaults(in defaults: UserDefaults = .standard) {
            for key in allKeys {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

// MARK: - Choices

/// A pickable AetherEngine option, identified by the raw value it is stored as.
nonisolated protocol AetherChoice: CaseIterable, Identifiable, RawRepresentable where RawValue: Hashable {
    var label: String { get }
}

nonisolated extension AetherChoice {
    var id: RawValue {
        rawValue
    }
}

/// `LoadOptions.preferredDecodePath`.
nonisolated enum AetherDecodePath: String, AetherChoice {
    case automatic
    case software

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .software: String(localized: "Software")
        }
    }
}

/// `LoadOptions.deinterlaceMode`: the GPU deinterlacer where the device has
/// one, or always the software filter.
nonisolated enum AetherDeinterlaceMode: String, AetherChoice {
    case auto
    case software

    var label: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .software: String(localized: "Software")
        }
    }
}

/// `LoadOptions.deinterlaceFieldRate`; only the hardware deinterlacer honours it.
nonisolated enum AetherDeinterlaceFieldRate: String, AetherChoice {
    /// One frame per field: 1080i50 becomes 1080p50.
    case field
    /// One frame per input frame: 1080i50 becomes 1080p25.
    case frame

    var label: String {
        switch self {
        case .field: String(localized: "Doubled")
        case .frame: String(localized: "Original")
        }
    }
}

/// `LoadOptions.liveJoinProfile`. Fast zap cuts shorter live segments so a
/// channel starts sooner, at the cost of more rebuffering on bursty origins.
nonisolated enum AetherLiveJoinProfile: String, AetherChoice {
    case standard
    case fastZap

    var label: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .fastZap: String(localized: "Fast Zap")
        }
    }
}

/// `LoadOptions.audioBridgeMode`: how audio that can't be passed through as-is
/// is re-encoded for the system player.
nonisolated enum AetherAudioBridgeMode: String, AetherChoice {
    /// Lossy multichannel that every sink accepts, including legacy ARC.
    case surroundCompat
    /// Lossless multichannel PCM; needs a receiver that takes it.
    case lossless

    var label: String {
        switch self {
        case .surroundCompat: String(localized: "Surround Compatible")
        case .lossless: String(localized: "Lossless")
        }
    }
}

/// `LoadOptions.dolbyVisionHandling`. Labels stay technical: no trademarks.
nonisolated enum AetherDynamicRangeHandling: String, AetherChoice {
    case automatic
    /// Present only the HDR10/HLG base layer of a layered HDR stream.
    case baseLayerOnly

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .baseLayerOnly: String(localized: "HDR Base Layer Only")
        }
    }
}

/// `LoadOptions.probesize`. `.auto` keeps the engine default (50 MB).
nonisolated enum AetherProbeSize: Int, AetherChoice {
    case auto = 0
    case oneMB = 1
    case twoMB = 2
    case fiveMB = 5
    case tenMB = 10
    case twentyMB = 20

    /// Bytes, or `nil` to keep the engine default.
    var optionValue: Int64? {
        self == .auto ? nil : Int64(rawValue) * 1_048_576
    }

    var label: String {
        self == .auto ? String(localized: "Default") : "\(rawValue) MB"
    }
}

/// `LoadOptions.maxAnalyzeDuration`. `.auto` keeps the engine default.
nonisolated enum AetherAnalyzeDuration: Int, AetherChoice {
    case auto = 0
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10

    /// Microseconds, or `nil` to keep the engine default.
    var optionValue: Int64? {
        self == .auto ? nil : Int64(rawValue) * 1_000_000
    }

    var label: String {
        self == .auto ? String(localized: "Default") : "\(rawValue) s"
    }
}

/// `LoadOptions.forwardBufferSegments` presets. 0 keeps the engine's window;
/// the engine clamps anything below 4.
nonisolated enum AetherForwardBufferPreset {
    static let values = [0, 6, 10, 20, 40, 75, 150]

    static func optionValue(_ segments: Int) -> Int? {
        segments > 0 ? segments : nil
    }

    static func label(_ segments: Int) -> String {
        segments > 0 ? String(localized: "\(segments) segments") : String(localized: "Default")
    }
}

/// Audio delay presets, in milliseconds. Positive plays audio later.
nonisolated enum AetherAudioDelayPreset {
    static let values = [-500, -400, -300, -200, -150, -100, -50, 0, 50, 100, 150, 200, 300, 400, 500]

    static func label(_ milliseconds: Int) -> String {
        milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
    }
}

// MARK: - Snapshot

/// A point-in-time read of every AetherEngine option, taken when a stream is
/// loaded.
nonisolated struct AetherEngineOptions: Equatable {
    var decodePath: AetherDecodePath
    var escalateToSoftware: Bool
    var deinterlaceMode: AetherDeinterlaceMode
    var deinterlaceFieldRate: AetherDeinterlaceFieldRate
    var liveJoinProfile: AetherLiveJoinProfile
    /// Segments; 0 keeps the engine default.
    var forwardBufferSegments: Int
    var probeSize: AetherProbeSize
    var analyzeDuration: AetherAnalyzeDuration
    var nativeRemoteHLS: Bool
    var audioBridgeMode: AetherAudioBridgeMode
    var dynamicRange: AetherDynamicRangeHandling
    var upscaleLowResolution: Bool
    /// Milliseconds.
    var audioDelay: Int
    var prepareNativeSubtitles: Bool
    /// The tvOS-only Match Content toggle.
    var matchContent: Bool

    static func load(from defaults: UserDefaults = .standard) -> AetherEngineOptions {
        typealias Keys = PlayerSettings.Aether
        return AetherEngineOptions(
            decodePath: AetherDecodePath(rawValue: defaults.string(forKey: Keys.decodePathKey) ?? "") ?? Keys.decodePathDefault,
            escalateToSoftware: defaults.bool(Keys.escalateToSoftwareKey, default: Keys.escalateToSoftwareDefault),
            deinterlaceMode: AetherDeinterlaceMode(rawValue: defaults.string(forKey: Keys.deinterlaceModeKey) ?? "") ?? Keys.deinterlaceModeDefault,
            deinterlaceFieldRate: AetherDeinterlaceFieldRate(rawValue: defaults.string(forKey: Keys.deinterlaceFieldRateKey) ?? "") ?? Keys.deinterlaceFieldRateDefault,
            liveJoinProfile: AetherLiveJoinProfile(rawValue: defaults.string(forKey: Keys.liveJoinProfileKey) ?? "") ?? Keys.liveJoinProfileDefault,
            forwardBufferSegments: max(0, defaults.integer(Keys.forwardBufferSegmentsKey, default: Keys.forwardBufferSegmentsDefault)),
            probeSize: AetherProbeSize(rawValue: defaults.integer(Keys.probeSizeKey, default: Keys.probeSizeDefault.rawValue)) ?? Keys.probeSizeDefault,
            analyzeDuration: AetherAnalyzeDuration(rawValue: defaults.integer(Keys.analyzeDurationKey, default: Keys.analyzeDurationDefault.rawValue)) ?? Keys.analyzeDurationDefault,
            nativeRemoteHLS: defaults.bool(Keys.nativeRemoteHLSKey, default: Keys.nativeRemoteHLSDefault),
            audioBridgeMode: AetherAudioBridgeMode(rawValue: defaults.string(forKey: Keys.audioBridgeModeKey) ?? "") ?? Keys.audioBridgeModeDefault,
            dynamicRange: AetherDynamicRangeHandling(rawValue: defaults.string(forKey: Keys.dynamicRangeKey) ?? "") ?? Keys.dynamicRangeDefault,
            upscaleLowResolution: defaults.bool(Keys.upscaleLowResolutionKey, default: Keys.upscaleLowResolutionDefault),
            audioDelay: defaults.integer(Keys.audioDelayKey, default: Keys.audioDelayDefault),
            prepareNativeSubtitles: defaults.bool(Keys.prepareNativeSubtitlesKey, default: Keys.prepareNativeSubtitlesDefault),
            matchContent: defaults.bool(Keys.matchContentKey, default: Keys.matchContentDefault)
        )
    }
}

// MARK: - Load mapping

/// What a load knows about the stream and where it plays.
nonisolated struct AetherLoadContext {
    var isLive: Bool
    var httpHeaders: [String: String]?
    /// Normalized preferred audio languages (`PlayerLanguageOptions`).
    var preferredAudioLanguages: [String]
    /// A Multiview tile or guide preview: secondary output, no display
    /// criteria.
    var isEmbedded: Bool
    /// Whether the user's Match Content toggle applies on this platform.
    var honorsMatchContentToggle: Bool = {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }()
}

/// The values a load hands AetherEngine. Field names follow `LoadOptions`;
/// enum raw values equal the engine's (`LiveJoinProfile` has none, so the
/// bridge switches on it). Fields Lume never sets keep the engine default and
/// are absent here — including `dvrWindowSeconds`, which stays nil (no DVR).
nonisolated struct AetherLoadPlan: Equatable {
    nonisolated enum OutputRole: String {
        case primary
        case secondary
    }

    var httpHeaders: [String: String]
    var isLive: Bool
    var preferredAudioLanguages: [String]
    var preferredDecodePath: AetherDecodePath
    var escalatesToSoftwarePath: Bool
    var deinterlaceMode: AetherDeinterlaceMode
    var deinterlaceFieldRate: AetherDeinterlaceFieldRate
    var liveJoinProfile: AetherLiveJoinProfile
    var forwardBufferSegments: Int?
    var probesize: Int64?
    var maxAnalyzeDuration: Int64?
    var nativeRemoteHLS: Bool
    var audioBridgeMode: AetherAudioBridgeMode
    var dolbyVisionHandling: AetherDynamicRangeHandling
    var upscalesLowResolutionVideo: Bool
    var audioDelaySeconds: Double
    var prepareNativeSubtitles: Bool
    var matchContentEnabled: Bool
    var sharedOutputRole: OutputRole

    static func make(options: AetherEngineOptions, context: AetherLoadContext) -> AetherLoadPlan {
        // Aether's own Match Content toggle decides on tvOS (owner decision);
        // embedded tiles and previews never apply display criteria.
        let matchContent = !context.isEmbedded
            && (!context.honorsMatchContentToggle || options.matchContent)
        return AetherLoadPlan(
            httpHeaders: context.httpHeaders ?? [:],
            isLive: context.isLive,
            preferredAudioLanguages: context.preferredAudioLanguages,
            preferredDecodePath: options.decodePath,
            escalatesToSoftwarePath: options.escalateToSoftware,
            deinterlaceMode: options.deinterlaceMode,
            deinterlaceFieldRate: options.deinterlaceFieldRate,
            liveJoinProfile: options.liveJoinProfile,
            forwardBufferSegments: AetherForwardBufferPreset.optionValue(options.forwardBufferSegments),
            probesize: options.probeSize.optionValue,
            maxAnalyzeDuration: options.analyzeDuration.optionValue,
            nativeRemoteHLS: options.nativeRemoteHLS,
            audioBridgeMode: options.audioBridgeMode,
            dolbyVisionHandling: options.dynamicRange,
            upscalesLowResolutionVideo: options.upscaleLowResolution,
            audioDelaySeconds: Double(options.audioDelay) / 1000,
            prepareNativeSubtitles: options.prepareNativeSubtitles,
            matchContentEnabled: matchContent,
            sharedOutputRole: context.isEmbedded ? .secondary : .primary
        )
    }
}
