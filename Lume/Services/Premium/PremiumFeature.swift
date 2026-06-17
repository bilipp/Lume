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
    case playbackControls

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .multiplePlaylists: "Unlimited Playlists"
        case .downloads: "Offline Downloads"
        case .multipleProfiles: "Multiple Profiles"
        case .trakt: "Trakt Integration"
        case .playbackControls: "Smart Playback"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .multiplePlaylists: "Add as many IPTV playlists as you like and switch between them."
        case .downloads: "Save movies and episodes to watch offline, anywhere."
        case .multipleProfiles: "Give everyone their own watch history, progress and favorites."
        case .trakt: "Scrobble what you watch and surface your Trakt watchlist on Home."
        case .playbackControls: "Autoplay the next episode, skip intros, and jump ahead with one tap."
        }
    }

    var systemImage: String {
        switch self {
        case .multiplePlaylists: "rectangle.stack.badge.plus"
        case .downloads: "arrow.down.circle"
        case .multipleProfiles: "person.2.crop.square.stack"
        case .trakt: "rectangle.stack.badge.play"
        case .playbackControls: "forward.end.alt"
        }
    }
}
