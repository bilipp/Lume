//
//  OnboardingStep.swift
//  Lume
//
//  The pages of the first-launch "How Lume Works" guide. Copy is deliberately
//  positioning copy, not marketing: Lume is a player and ships with no content
//  of its own, so no step names or suggests a provider (see ANTI_PIRACY.md).
//  Every case exists on every platform; `steps` is what decides which ones a
//  platform actually shows, so the tour never describes a surface it lacks.
//

import Foundation

nonisolated enum OnboardingStep: String, CaseIterable, Identifiable {
    case whatIsLume
    case addProvider
    case browseLibrary
    case liveTV
    case search
    case quickSwitch
    case multiView

    var id: String {
        rawValue
    }

    /// The steps this platform shows, in order.
    static var steps: [OnboardingStep] {
        #if os(tvOS)
            [.whatIsLume, .addProvider, .browseLibrary, .liveTV, .search, .quickSwitch, .multiView]
        #else
            [.whatIsLume, .addProvider, .browseLibrary, .liveTV, .search]
        #endif
    }

    var title: LocalizedStringResource {
        switch self {
        case .whatIsLume:
            LocalizedStringResource(
                "Lume is a player",
                comment: "Title of the first page of the first-launch guide, stating that Lume plays your own service and supplies no content itself"
            )
        case .addProvider:
            LocalizedStringResource(
                "Bring your own service",
                comment: "Title of the first-launch guide page explaining that the viewer connects their own Xtream Codes or M3U account"
            )
        case .browseLibrary:
            LocalizedStringResource(
                "Your library, organized",
                comment: "Title of the first-launch guide page describing the Movies and Series tabs"
            )
        case .liveTV: "Live TV"
        case .search: "Search"
        case .quickSwitch: "Quick Switch"
        case .multiView: "Multi-View"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .whatIsLume:
            LocalizedStringResource(
                "It ships with no channels, streams, or content of its own — it gives what you already pay for a native home on every Apple device.",
                comment: "Body of the first-launch guide page stating that Lume supplies no content of its own"
            )
        case .addProvider:
            LocalizedStringResource(
                "Sign in with your own Xtream Codes credentials or point Lume at an M3U playlist. The catalog is indexed on device, so browsing stays instant.",
                comment: "Body of the first-launch guide page explaining how to connect an existing IPTV account"
            )
        case .browseLibrary:
            LocalizedStringResource(
                "Movies and Series arrive sorted by category and enriched with artwork, cast, trailers and ratings. Your progress follows you across your devices.",
                comment: "Body of the first-launch guide page describing the Movies and Series tabs"
            )
        case .liveTV:
            LocalizedStringResource(
                "Flip through channels with a full TV Guide, see what is on now, and jump straight back to the last thing you watched.",
                comment: "Body of the first-launch guide page describing the Live TV tab and the TV Guide"
            )
        case .search:
            LocalizedStringResource(
                "Find any channel, movie or episode across every playlist you have added, as you type.",
                comment: "Body of the first-launch guide page describing search"
            )
        case .quickSwitch:
            LocalizedStringResource(
                "Press Play/Pause on the Home screen to change playlist or profile without losing your place.",
                comment: "Body of the tvOS-only first-launch guide page describing the Play/Pause quick-switch gesture"
            )
        case .multiView:
            LocalizedStringResource(
                "Watch up to four live channels side by side on the big screen.",
                comment: "Body of the tvOS-only first-launch guide page describing Multi-View"
            )
        }
    }

    var systemImage: String {
        switch self {
        case .whatIsLume: "play.tv"
        case .addProvider: "rectangle.stack.badge.plus"
        case .browseLibrary: "film.stack"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .search: "magnifyingglass"
        case .quickSwitch: "playpause.fill"
        case .multiView: "rectangle.split.2x2"
        }
    }
}
