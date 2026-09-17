//
//  ExternalPlayer.swift
//  Lume
//
//  Hand-off to third-party player apps via their documented deep-link APIs.
//  When the user prefers an external player in Settings, playback start sites
//  call `ExternalPlayback.open(_:)` first and only fall through to the
//  built-in player when the hand-off cannot happen (player not installed,
//  preference off, the selected scope excludes this kind of stream, or the
//  media is a local download other apps can't read).
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
    case vidhub

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .infuse: "Infuse"
        case .vlc: "VLC"
        case .vidhub: "VidHub"
        }
    }

    /// The custom URL scheme the app registers. Each scheme must also be
    /// listed under `LSApplicationQueriesSchemes` in Info.plist for
    /// `canOpenURL(_:)` to resolve it.
    var scheme: String {
        switch self {
        case .infuse: "infuse"
        case .vlc: "vlc-x-callback"
        case .vidhub: "open-vidhub"
        }
    }

    /// Builds the deep link that opens `streamURL` in the player.
    ///
    /// - Infuse: `infuse://x-callback-url/play?url=…`
    ///   (https://support.firecore.com/hc/en-us/articles/215090997)
    /// - VLC: `vlc-x-callback://x-callback-url/stream?url=…`
    ///   (https://wiki.videolan.org/Documentation:IOS/#x-callback-url)
    /// - VidHub: `open-vidhub://x-callback-url/open?url=…`
    ///   (https://vidhub.okaapps.com/3rd-party-app-integration/). The docs
    ///   steer new integrations to `/play`, but the shipping App Store build
    ///   only answers `/open`: it launches and ignores an unrecognised path,
    ///   and since we send no `x-error` callback the failure is silent.
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
        case .vidhub: "open"
        }
        return URL(string: "\(scheme)://x-callback-url/\(action)?url=\(encoded)")
    }
}

/// Which content the external-player hand-off applies to. Not every player
/// handles every kind of stream — Infuse, for one, plays VOD but no live TV —
/// so the scope is a separate preference from the player choice.
enum ExternalPlayerScope: String, CaseIterable, Identifiable {
    /// Both VOD and live TV.
    case all
    /// Movies and episodes only; live channels stay in the built-in player.
    case vod
    /// Live channels only; movies and episodes stay in the built-in player.
    case live

    /// VOD only: the players Lume hands off to are VOD-first (Infuse plays no
    /// live streams at all), so limiting the hand-off is the safe default.
    static let `default` = ExternalPlayerScope.vod

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .all: String(localized: "Everything")
        case .vod: String(localized: "Movies & Series")
        case .live: String(localized: "Live TV")
        }
    }

    /// Whether media of `kind` is handed off under this scope.
    func includes(_ kind: PlayableMedia.Kind) -> Bool {
        switch self {
        case .all: true
        case .vod: kind == .vod
        case .live: kind == .live
        }
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

    /// The content the hand-off applies to. Anything the picker didn't write —
    /// including the unset default — means movies and series only.
    static var scope: ExternalPlayerScope {
        guard let raw = UserDefaults.standard.string(forKey: PlayerSettings.externalPlayerScopeKey),
              let scope = ExternalPlayerScope(rawValue: raw) else { return .default }
        return scope
    }

    /// The player `media` would be handed off to, or `nil` when it stays in the
    /// built-in player — because no player is selected, the current scope
    /// excludes this kind of stream, or the media is a local download other
    /// apps cannot read from Lume's sandbox.
    static func target(for media: PlayableMedia) -> ExternalPlayer? {
        guard let player = preferred, scope.includes(media.kind), !media.url.isFileURL else { return nil }
        return player
    }

    /// Opens `media` in the preferred external player. Returns `true` when the
    /// hand-off happened; on `false` the caller starts the built-in player so
    /// playback never dead-ends.
    static func open(_ media: PlayableMedia) -> Bool {
        guard let player = target(for: media),
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
