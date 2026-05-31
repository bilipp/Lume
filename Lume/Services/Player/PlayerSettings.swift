import Foundation

enum PlayerEngineKind: String, CaseIterable, Identifiable {
    case ksPlayer
    case avPlayer

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .ksPlayer: "KSPlayer"
        case .avPlayer: "AVPlayer"
        }
    }

    var subtitle: String {
        switch self {
        case .ksPlayer: "FFmpeg-backed. Recommended for IPTV streams."
        case .avPlayer: "Native Apple player. Best for HLS and MP4."
        }
    }

    static var defaultValue: PlayerEngineKind {
        #if canImport(KSPlayer)
            return .ksPlayer
        #else
            return .avPlayer
        #endif
    }
}

enum PlayerSettings {
    static let engineKey = "player.engine"
}
