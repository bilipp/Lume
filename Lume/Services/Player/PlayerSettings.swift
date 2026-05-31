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
        case .ksPlayer: "KSPlayer is a powerful third-party player that supports a wide range of formats, including those commonly used in IPTV streams."
        case .avPlayer: "Native Apple player. Best for HLS and MP4. But does not support many formats used in IPTV streams."
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
