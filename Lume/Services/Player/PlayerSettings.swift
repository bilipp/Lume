import Foundation

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

    var subtitle: String {
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
        case .vlcKit, .ksPlayer: true
        case .avPlayer: false
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
}
