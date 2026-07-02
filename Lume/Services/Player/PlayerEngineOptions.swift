//
//  PlayerEngineOptions.swift
//  Lume
//
//  The per-engine playback option model: the pickable choices (decode threads,
//  deinterlace modes, clock tuning, buffer presets) and the two snapshot structs
//  the engines read at configure time. The settings UI writes plain values to
//  `UserDefaults` via `@AppStorage`; the engines read them back here, so neither
//  side has to thread a growing argument list through the player.
//

import Foundation

// MARK: - VLCKit choices

/// FFmpeg decode-thread count exposed by libvlc's `avcodec-threads`. `0` lets
/// FFmpeg choose based on the host's core count.
enum VLCDecodeThreads: Int, CaseIterable, Identifiable {
    case auto = 0
    case one = 1
    case two = 2
    case four = 4
    case six = 6
    case eight = 8

    var id: Int {
        rawValue
    }

    var label: String {
        self == .auto ? String(localized: "Automatic") : "\(rawValue)"
    }
}

/// libvlc deinterlace algorithms (`deinterlace-mode`). The raw values are the
/// exact filter names passed to libvlc.
enum VLCDeinterlaceMode: String, CaseIterable, Identifiable {
    case blend
    case bob
    case linear
    case algorithmX = "x"
    case yadif
    case yadif2x
    case mean
    case discard

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .blend: "Blend"
        case .bob: "Bob"
        case .linear: "Linear"
        case .algorithmX: "X"
        case .yadif: "Yadif"
        case .yadif2x: "Yadif (2x)"
        case .mean: "Mean"
        case .discard: "Discard"
        }
    }
}

/// libvlc `clock-jitter` tuning (input clock jitter tolerance, ms). `.auto`
/// leaves the option unset so libvlc keeps its built-in default.
enum VLCClockJitter: Int, CaseIterable, Identifiable {
    case auto = -1
    case off = 0
    case low = 200
    case medium = 500
    case high = 1000

    var id: Int {
        rawValue
    }

    /// The value to emit to libvlc, or `nil` to leave the option unset.
    var optionValue: Int? {
        self == .auto ? nil : rawValue
    }

    var label: String {
        switch self {
        case .auto: String(localized: "Default")
        case .off: "0 ms"
        default: "\(rawValue) ms"
        }
    }
}

/// libvlc `clock-synchro` (input clock synchronisation). `.automatic` leaves
/// the option unset.
enum VLCClockSynchro: Int, CaseIterable, Identifiable {
    case automatic = -1
    case disabled = 0
    case enabled = 1

    var id: Int {
        rawValue
    }

    /// The value to emit to libvlc, or `nil` to leave the option unset.
    var optionValue: Int? {
        self == .automatic ? nil : rawValue
    }

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .disabled: String(localized: "Disabled")
        case .enabled: String(localized: "Enabled")
        }
    }
}

/// Caching presets (milliseconds) offered for VLC's live and on-demand buffers.
enum VLCCachingPreset {
    static let values = [300, 500, 1000, 1500, 2000, 3000, 5000]

    static func label(_ milliseconds: Int) -> String {
        "\(milliseconds) ms"
    }
}

// MARK: - KSPlayer choices

/// Which underlying KSPlayer engine handles playback first. KSPlayer tries this
/// engine and only falls back to the other when it fails to open a stream.
///
/// - `avPlayer`: Apple's AVFoundation player — efficient and native for HLS/MP4,
///   but it ignores most KSPlayer options (buffering, hardware decode, etc.) for
///   streams it can play itself.
/// - `ffmpeg`: KSPlayer's FFmpeg-based engine, which honours every option below
///   for all streams and supports the broadest range of formats.
enum KSPrimaryEngine: String, CaseIterable, Identifiable {
    case avPlayer
    case ffmpeg

    /// FFmpeg by default: it honours the buffering and decode options for every
    /// stream, where AVPlayer silently ignores most of them for HLS/MP4.
    static let defaultValue: KSPrimaryEngine = .ffmpeg

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .avPlayer: "AVPlayer"
        case .ffmpeg: "FFmpeg"
        }
    }
}

/// Forward-buffer presets (seconds) offered for KSPlayer's live and on-demand
/// streams.
enum KSBufferPreset {
    static let values = [1, 2, 4, 8, 16, 30]

    static func label(_ seconds: Int) -> String {
        "\(seconds) s"
    }
}

/// Maximum-buffer presets (seconds) for KSPlayer.
enum KSMaxBufferPreset {
    static let values = [10, 20, 30, 60, 120]

    static func label(_ seconds: Int) -> String {
        "\(seconds) s"
    }
}

// MARK: - Snapshots

/// A point-in-time read of every VLCKit option, taken when the coordinator
/// starts (or reloads) a stream.
struct VLCPlayerOptions {
    var hardwareDecode: Bool
    var decodeThreads: Int
    var skipFrames: Bool
    var dropLateFrames: Bool
    var httpReconnect: Bool
    var deinterlace: Bool
    var deinterlaceMode: String
    var liveBuffer: Int
    var vodBuffer: Int
    /// `nil` when the user left the clock options on their automatic default,
    /// in which case the option is not emitted to libvlc at all.
    var clockJitter: Int?
    var clockSynchro: Int?

    static func load(from defaults: UserDefaults = .standard) -> VLCPlayerOptions {
        let jitter = VLCClockJitter(rawValue: defaults.integer(PlayerSettings.VLC.clockJitterKey, default: VLCClockJitter.auto.rawValue)) ?? .auto
        let synchro = VLCClockSynchro(rawValue: defaults.integer(PlayerSettings.VLC.clockSynchroKey, default: VLCClockSynchro.automatic.rawValue)) ?? .automatic
        return VLCPlayerOptions(
            hardwareDecode: defaults.bool(PlayerSettings.VLC.hardwareDecodeKey, default: PlayerSettings.VLC.hardwareDecodeDefault),
            decodeThreads: defaults.integer(PlayerSettings.VLC.decodeThreadsKey, default: PlayerSettings.VLC.decodeThreadsDefault),
            skipFrames: defaults.bool(PlayerSettings.VLC.skipFramesKey, default: PlayerSettings.VLC.skipFramesDefault),
            dropLateFrames: defaults.bool(PlayerSettings.VLC.dropLateFramesKey, default: PlayerSettings.VLC.dropLateFramesDefault),
            httpReconnect: defaults.bool(PlayerSettings.VLC.httpReconnectKey, default: PlayerSettings.VLC.httpReconnectDefault),
            deinterlace: defaults.bool(PlayerSettings.deinterlaceKey, default: PlayerSettings.deinterlaceDefault),
            deinterlaceMode: defaults.string(forKey: PlayerSettings.VLC.deinterlaceModeKey) ?? VLCDeinterlaceMode.blend.rawValue,
            liveBuffer: defaults.integer(PlayerSettings.VLC.liveBufferKey, default: PlayerSettings.VLC.liveBufferDefault),
            vodBuffer: defaults.integer(PlayerSettings.VLC.vodBufferKey, default: PlayerSettings.VLC.vodBufferDefault),
            clockJitter: jitter.optionValue,
            clockSynchro: synchro.optionValue
        )
    }
}

/// A point-in-time read of every KSPlayer option, taken when the engine view
/// builds its `KSOptions`.
struct KSPlayerOptions {
    var hardwareDecode: Bool
    var asyncDecompression: Bool
    var secondOpen: Bool
    var accurateSeek: Bool
    var loopPlay: Bool
    var systemProxy: Bool
    var autoDeinterlace: Bool
    var autoRotate: Bool
    var adaptive: Bool
    var noBuffer: Bool
    var codecLowDelay: Bool
    var autoPip: Bool
    /// Whether KSPlayer picks the first embedded subtitle track on open.
    /// Deliberately off by default — the subtitle overlay renders whatever is
    /// selected, so auto-select would show subtitles on every playback start.
    var autoSelectSubtitle: Bool
    var primaryEngine: KSPrimaryEngine
    /// Forward-buffer durations, in seconds.
    var liveBuffer: Int
    var vodBuffer: Int
    var maxBuffer: Int

    static func load(from defaults: UserDefaults = .standard) -> KSPlayerOptions {
        KSPlayerOptions(
            hardwareDecode: defaults.bool(PlayerSettings.KSPlayer.hardwareDecodeKey, default: PlayerSettings.KSPlayer.hardwareDecodeDefault),
            asyncDecompression: defaults.bool(PlayerSettings.KSPlayer.asyncDecompressionKey, default: PlayerSettings.KSPlayer.asyncDecompressionDefault),
            secondOpen: defaults.bool(PlayerSettings.KSPlayer.secondOpenKey, default: PlayerSettings.KSPlayer.secondOpenDefault),
            accurateSeek: defaults.bool(PlayerSettings.KSPlayer.accurateSeekKey, default: PlayerSettings.KSPlayer.accurateSeekDefault),
            loopPlay: defaults.bool(PlayerSettings.KSPlayer.loopPlayKey, default: PlayerSettings.KSPlayer.loopPlayDefault),
            systemProxy: defaults.bool(PlayerSettings.KSPlayer.systemProxyKey, default: PlayerSettings.KSPlayer.systemProxyDefault),
            autoDeinterlace: defaults.bool(PlayerSettings.KSPlayer.autoDeinterlaceKey, default: PlayerSettings.KSPlayer.autoDeinterlaceDefault),
            autoRotate: defaults.bool(PlayerSettings.KSPlayer.autoRotateKey, default: PlayerSettings.KSPlayer.autoRotateDefault),
            adaptive: defaults.bool(PlayerSettings.KSPlayer.adaptiveKey, default: PlayerSettings.KSPlayer.adaptiveDefault),
            noBuffer: defaults.bool(PlayerSettings.KSPlayer.noBufferKey, default: PlayerSettings.KSPlayer.noBufferDefault),
            codecLowDelay: defaults.bool(PlayerSettings.KSPlayer.codecLowDelayKey, default: PlayerSettings.KSPlayer.codecLowDelayDefault),
            autoPip: defaults.bool(PlayerSettings.KSPlayer.autoPipKey, default: PlayerSettings.KSPlayer.autoPipDefault),
            autoSelectSubtitle: defaults.bool(PlayerSettings.KSPlayer.autoSelectSubtitleKey, default: PlayerSettings.KSPlayer.autoSelectSubtitleDefault),
            primaryEngine: KSPrimaryEngine(rawValue: defaults.string(forKey: PlayerSettings.KSPlayer.primaryEngineKey) ?? "") ?? .defaultValue,
            liveBuffer: defaults.integer(PlayerSettings.KSPlayer.liveBufferKey, default: PlayerSettings.KSPlayer.liveBufferDefault),
            vodBuffer: defaults.integer(PlayerSettings.KSPlayer.vodBufferKey, default: PlayerSettings.KSPlayer.vodBufferDefault),
            maxBuffer: defaults.integer(PlayerSettings.KSPlayer.maxBufferKey, default: PlayerSettings.KSPlayer.maxBufferDefault)
        )
    }
}

// MARK: - UserDefaults default-aware reads

/// `@AppStorage` writes nothing until the user first changes a control, so a
/// plain `bool(forKey:)`/`integer(forKey:)` would read `false`/`0` for an
/// untouched setting rather than the intended default. These helpers fall back
/// to the supplied default when the key is absent, matching `@AppStorage`'s own
/// behaviour.
extension UserDefaults {
    func bool(_ key: String, default def: Bool) -> Bool {
        object(forKey: key) == nil ? def : bool(forKey: key)
    }

    func integer(_ key: String, default def: Int) -> Int {
        object(forKey: key) == nil ? def : integer(forKey: key)
    }
}
