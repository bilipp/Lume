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
}
