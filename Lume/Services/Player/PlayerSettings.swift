import Foundation
import SwiftUI

enum PlayerEngineKind: String, CaseIterable, Identifiable {
    case vlcKit
    case ksPlayer
    case avPlayer

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .vlcKit: "VLCKit"
        case .ksPlayer: "KSPlayer"
        case .avPlayer: "AVPlayer"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .vlcKit: "VLCKit 4 is VLC's native engine. Plays virtually any format and codec, with hardware-accelerated 4K HDR, Picture in Picture, and the broadest IPTV compatibility."
        case .ksPlayer: "KSPlayer is a powerful third-party player that supports a wide range of formats, including those commonly used in IPTV streams."
        case .avPlayer: "Native Apple player. Best for HLS and MP4. But does not support many formats used in IPTV streams."
        }
    }

    /// Engines that draw their own in-player controls overlay (close button,
    /// transport, scrubber). The host should not render its own close button
    /// for these, to avoid duplicate controls.
    var rendersOwnControls: Bool {
        switch self {
        case .vlcKit, .ksPlayer, .avPlayer: true
        }
    }

    static var defaultValue: PlayerEngineKind {
        #if canImport(VLCKitSPM)
            return .vlcKit
        #elseif canImport(KSPlayer)
            return .ksPlayer
        #else
            return .avPlayer
        #endif
    }
}

enum PlayerSettings {
    static let engineKey = "player.engine"

    // MARK: - Playback behaviour

    /// Engine-independent playback preferences for episodic content. Both default
    /// on, matching the behaviour viewers expect from a binge-friendly player.
    enum Playback {
        /// Automatically start the next episode once the current one finishes.
        static let autoPlayNextKey = "player.autoPlayNext"
        /// Surface a focused "Next Episode" button once the current episode is
        /// near its end (mirrors the ≥90% "watched" line).
        static let showNextEpisodeButtonKey = "player.showNextEpisodeButton"
        /// Surface a "Skip Intro" / "Skip Recap" button while the playhead sits
        /// inside an intro or recap window known to IntroDB (TV episodes only).
        static let showSkipIntroButtonKey = "player.showSkipIntroButton"

        static let autoPlayNextDefault = true
        static let showNextEpisodeButtonDefault = true
        static let showSkipIntroButtonDefault = true

        /// Whether the skip-intro affordance is enabled, read off `UserDefaults`
        /// directly (so the player host needn't hold an `@AppStorage` that would
        /// re-render the whole player tree when toggled). Honours the default
        /// when the key was never written.
        static var showSkipIntroButton: Bool {
            UserDefaults.standard.object(forKey: showSkipIntroButtonKey) as? Bool
                ?? showSkipIntroButtonDefault
        }
    }

    /// Legacy top-level key for VLC's deinterlace toggle, kept stable so the
    /// preference survives this option being moved under the VLC engine area.
    static let deinterlaceKey = "player.deinterlace"

    /// Default deinterlacing state.
    ///
    /// Off on iOS/tvOS: interlaced H.264 can't use VideoToolbox there (it aborts
    /// on interlaced content) and falls back to software decode, so the lighter
    /// default is to show frames woven rather than add a software deinterlace
    /// pass on top. Combing may be visible on motion; the software decoder is
    /// run multithreaded (see VLCPlayerCoordinator.applyMediaOptions) so either
    /// way it can keep up. On by default on macOS, where VideoToolbox handles
    /// deinterlacing in hardware.
    static var deinterlaceDefault: Bool {
        #if os(tvOS) || os(iOS)
            false
        #else
            true
        #endif
    }

    // MARK: - VLCKit options

    /// Storage keys and defaults for the VLCKit engine. Every libvlc option the
    /// player applies is surfaced as a user setting; the defaults reproduce the
    /// values the engine previously hard-coded.
    enum VLC {
        static let hardwareDecodeKey = "player.vlc.hardwareDecode"
        static let decodeThreadsKey = "player.vlc.decodeThreads"
        static let skipFramesKey = "player.vlc.skipFrames"
        static let dropLateFramesKey = "player.vlc.dropLateFrames"
        static let httpReconnectKey = "player.vlc.httpReconnect"
        static let deinterlaceModeKey = "player.vlc.deinterlaceMode"
        static let liveBufferKey = "player.vlc.liveBuffer"
        static let vodBufferKey = "player.vlc.vodBuffer"
        static let clockJitterKey = "player.vlc.clockJitter"
        static let clockSynchroKey = "player.vlc.clockSynchro"

        static let hardwareDecodeDefault = true
        /// 0 == let FFmpeg pick (`auto`).
        static let decodeThreadsDefault = 0
        static let skipFramesDefault = true
        static let dropLateFramesDefault = true
        static let httpReconnectDefault = true
        /// Network/live caching for live streams, in milliseconds.
        static let liveBufferDefault = 3000
        /// Network/file caching for on-demand streams, in milliseconds.
        static let vodBufferDefault = 1500
    }

    // MARK: - KSPlayer options

    /// Storage keys and defaults for the KSPlayer engine, mapped 1:1 onto
    /// `KSOptions` fields. Defaults match `KSOptions`' own defaults except where
    /// the app deliberately diverged (asynchronous decompression on, so the
    /// hardware path actually engages — see the KSPlayer hardware-decode gate).
    enum KSPlayer {
        static let hardwareDecodeKey = "player.ks.hardwareDecode"
        static let asyncDecompressionKey = "player.ks.asyncDecompression"
        static let secondOpenKey = "player.ks.secondOpen"
        static let accurateSeekKey = "player.ks.accurateSeek"
        static let loopPlayKey = "player.ks.loopPlay"
        static let systemProxyKey = "player.ks.systemProxy"
        static let autoDeinterlaceKey = "player.ks.autoDeinterlace"
        static let autoRotateKey = "player.ks.autoRotate"
        static let adaptiveKey = "player.ks.adaptive"
        static let noBufferKey = "player.ks.noBuffer"
        static let codecLowDelayKey = "player.ks.codecLowDelay"
        static let autoPipKey = "player.ks.autoPip"
        static let liveBufferKey = "player.ks.liveBuffer"
        static let vodBufferKey = "player.ks.vodBuffer"
        static let maxBufferKey = "player.ks.maxBuffer"
        static let primaryEngineKey = "player.ks.primaryEngine"

        static let hardwareDecodeDefault = true
        static let asyncDecompressionDefault = true
        static let secondOpenDefault = false
        static let accurateSeekDefault = false
        static let loopPlayDefault = false
        static let systemProxyDefault = true
        static let autoDeinterlaceDefault = false
        static let autoRotateDefault = true
        static let adaptiveDefault = true
        static let noBufferDefault = false
        static let codecLowDelayDefault = false
        static let autoPipDefault = true
        /// Minimum forward buffer for live streams, in seconds.
        static let liveBufferDefault = 4
        /// Minimum forward buffer for on-demand streams, in seconds.
        static let vodBufferDefault = 8
        /// Maximum buffer, in seconds.
        static let maxBufferDefault = 30
    }
}
