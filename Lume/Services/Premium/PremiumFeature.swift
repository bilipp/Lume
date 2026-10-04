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
    case trakt
    case simkl
    case playbackControls
    case recommendations
    case multiView
    case guidePreview
    case sportsHub

    var id: String {
        rawValue
    }

    /// The features this platform offers. Guide Preview only exists in the
    /// tvOS Guide, so other platforms never advertise it.
    static var available: [PremiumFeature] {
        #if os(tvOS)
            allCases
        #else
            allCases.filter { $0 != .guidePreview }
        #endif
    }

    var title: LocalizedStringResource {
        switch self {
        case .multiplePlaylists: "Unlimited Playlists"
        case .downloads: "Offline Downloads"
        case .multipleProfiles: "Multiple Profiles"
        case .trakt: "Trakt Integration"
        case .simkl: "Simkl Integration"
        case .playbackControls: "Smart Playback"
        case .recommendations: "For You Recommendations"
        case .multiView: "Multi-View"
        case .guidePreview: "Guide Preview"
        case .sportsHub: "Sports Hub"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .multiplePlaylists: "Add as many IPTV playlists as you like and switch between them."
        case .downloads: "Save movies and episodes to watch offline, anywhere."
        case .multipleProfiles: "Give everyone their own watch history, progress and favorites."
        case .trakt: "Scrobble what you watch and surface your Trakt watchlist on Home."
        case .simkl: "Scrobble what you watch to Simkl, import your Simkl history and surface your Simkl watchlist on Home."
        case .playbackControls: "Autoplay the next episode, skip intros, and jump ahead with one tap."
        case .recommendations: "Get an on-device \"For You\" row tuned to your taste from your library and what you watch."
        case .multiView: "Watch up to four live channels side by side. Each tile can come from a different playlist, which helps if your provider allows only one connection per account."
        case .guidePreview: "Preview the focused channel, muted, right in the TV Guide."
        case .sportsHub: "Follow your leagues and teams — fixtures, live scores, standings and one tap to the channel that's carrying the game."
        }
    }

    var systemImage: String {
        switch self {
        case .multiplePlaylists: "rectangle.stack.badge.plus"
        case .downloads: "arrow.down.circle"
        case .multipleProfiles: "person.2.crop.square.stack"
        case .trakt: "arrow.trianglehead.2.clockwise.rotate.90.circle"
        case .simkl: "arrow.trianglehead.2.clockwise.rotate.90.circle"
        case .playbackControls: "forward.end.alt"
        case .recommendations: "sparkles"
        case .multiView: "rectangle.split.2x2"
        case .guidePreview: "play.rectangle"
        case .sportsHub: "sportscourt"
        }
    }
}
