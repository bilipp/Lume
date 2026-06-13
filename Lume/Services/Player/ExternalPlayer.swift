//
//  ExternalPlayer.swift
//  Lume
//
//  Hand-off to third-party player apps via their documented deep-link APIs.
//  When the user prefers an external player in Settings, playback start sites
//  call `ExternalPlayback.open(_:)` first and only fall through to the
//  built-in player when the hand-off cannot happen (player not installed,
//  preference off, or the media is a local download other apps can't read).
//

import Foundation
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

/// A third-party player app Lume can hand playback off to.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case infuse
    case vlc

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .infuse: "Infuse"
        case .vlc: "VLC"
        }
    }

    /// The custom URL scheme the app registers. Each scheme must also be
    /// listed under `LSApplicationQueriesSchemes` in Info.plist for
    /// `canOpenURL(_:)` to resolve it.
    var scheme: String {
        switch self {
        case .infuse: "infuse"
        case .vlc: "vlc-x-callback"
        }
    }

    /// Builds the deep link that opens `streamURL` in the player.
    ///
    /// - Infuse: `infuse://x-callback-url/play?url=…`
    ///   (https://support.firecore.com/hc/en-us/articles/215090997)
    /// - VLC: `vlc-x-callback://x-callback-url/stream?url=…`
    ///   (https://wiki.videolan.org/Documentation:IOS/#x-callback-url)
    func deepLink(for streamURL: URL) -> URL? {
        // The stream URL is carried as a query parameter value, so every
        // reserved character — including `&`, `=` and `?`, which
        // `.urlQueryAllowed` keeps literal — must be percent-encoded or a
        // stream URL with its own query would be truncated by the target app.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+/:,")
        guard let encoded = streamURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let action = switch self {
        case .infuse: "play"
        case .vlc: "stream"
        }
        return URL(string: "\(scheme)://x-callback-url/\(action)?url=\(encoded)")
    }
}

/// Reads the user's external-player preference and performs the hand-off.
enum ExternalPlayback {
    /// The player selected in Settings, or `nil` when playback stays in the
    /// built-in player.
    static var preferred: ExternalPlayer? {
        guard let raw = UserDefaults.standard.string(forKey: PlayerSettings.externalPlayerKey) else { return nil }
        return ExternalPlayer(rawValue: raw)
    }

    /// Opens `media` in the preferred external player. Returns `true` when the
    /// hand-off happened; on `false` the caller starts the built-in player so
    /// playback never dead-ends. Local downloads always return `false` — other
    /// apps cannot read files inside Lume's sandbox.
    static func open(_ media: PlayableMedia) -> Bool {
        guard let player = preferred,
              !media.url.isFileURL,
              let deepLink = player.deepLink(for: media.url) else { return false }
        #if os(macOS)
            guard NSWorkspace.shared.urlForApplication(toOpen: deepLink) != nil else { return false }
            return NSWorkspace.shared.open(deepLink)
        #else
            guard UIApplication.shared.canOpenURL(deepLink) else { return false }
            UIApplication.shared.open(deepLink)
            return true
        #endif
    }
}
