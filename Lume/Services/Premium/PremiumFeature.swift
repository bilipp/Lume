//
//  PremiumFeature.swift
//  Lume
//
//  The catalogue of features gated behind Lume Pro on the App Store build.
//  Drives both the paywall's benefits list and the per-feature highlight shown
//  when a gate is hit. Sideloaded builds never see any of this (everything is
//  unlocked), so the copy speaks to the App Store audience.
//

import Foundation

enum PremiumFeature: String, CaseIterable, Identifiable {
    case multiplePlaylists
    case downloads
    case multipleProfiles
    case watchSync
    case playbackControls
    case recommendations
    case multiView
    case guidePreview
    case sportsHub
    case recordingServer
    case chromecast

    var id: String {
        rawValue
    }

    /// The features this platform offers. Guide Preview only exists in the
    /// tvOS Guide and Chromecast only on iPhone and iPad, so other platforms
    /// never advertise them.
    static var available: [PremiumFeature] {
        allCases.filter(\.isOnThisPlatform)
    }

    private var isOnThisPlatform: Bool {
        switch self {
        case .guidePreview: Self.isTV
        case .chromecast: Self.isIOS
        default: true
        }
    }

    #if os(tvOS)
        private static let isTV = true
    #else
        private static let isTV = false
    #endif

    #if os(iOS)
        private static let isIOS = true
    #else
        private static let isIOS = false
    #endif

    var title: LocalizedStringResource {
        switch self {
        case .multiplePlaylists: "Unlimited Playlists"
        case .downloads: "Offline Downloads"
        case .multipleProfiles: "Multiple Profiles"
        case .watchSync: "Trakt & Simkl Sync"
        case .playbackControls: "Smart Playback"
        case .recommendations: "For You Recommendations"
        case .multiView: "Multi-View"
        case .guidePreview: "Guide Preview"
        case .sportsHub: "Sports Hub"
        case .recordingServer: "Recording Server"
        case .chromecast:
            LocalizedStringResource(
                "premium.chromecast.title",
                defaultValue: "Chromecast",
                comment: "Lume Pro feature title: send playback to a Chromecast."
            )
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .multiplePlaylists: "Add as many IPTV playlists as you like and switch between them."
        case .downloads: "Save movies and episodes to watch offline, anywhere."
        case .multipleProfiles: "Give everyone their own watch history, progress and favorites."
        case .watchSync: "Scrobble what you watch to Trakt or Simkl, import your history and surface your watchlist on Home."
        case .playbackControls: "Autoplay the next episode, skip intros, and jump ahead with one tap."
        case .recommendations: "Get an on-device \"For You\" row tuned to your taste from your library and what you watch."
        case .multiView: "Watch up to four live channels side by side. Each tile can come from a different playlist, which helps if your provider allows only one connection per account."
        case .guidePreview: "Preview the focused channel, muted, right in the TV Guide."
        case .sportsHub: "Follow your leagues and teams — fixtures, live scores, standings and one tap to the channel that's carrying the game."
        case .recordingServer: "Record live TV and schedule shows from the guide on your own LumeRecorder server, then watch them on every device."
        case .chromecast:
            LocalizedStringResource(
                "premium.chromecast.subtitle",
                defaultValue: "Send live TV, movies and episodes from your iPhone or iPad to a Chromecast and control them from Lume.",
                comment: "Lume Pro feature description: casting from iPhone or iPad to a Chromecast on the same network."
            )
        }
    }

    var systemImage: String {
        switch self {
        case .multiplePlaylists: "rectangle.stack.badge.plus"
        case .downloads: "arrow.down.circle"
        case .multipleProfiles: "person.2.crop.square.stack"
        case .watchSync: "arrow.trianglehead.2.clockwise.rotate.90.circle"
        case .playbackControls: "forward.end.alt"
        case .recommendations: "sparkles"
        case .multiView: "rectangle.split.2x2"
        case .guidePreview: "play.rectangle"
        case .sportsHub: "sportscourt"
        case .recordingServer: "record.circle"
        case .chromecast: "tv.badge.wifi"
        }
    }
}
