//
//  SettingsCategory.swift
//  Lume
//
//  The top-level Settings categories, in the one order every platform shares:
//  the iOS / macOS root list and the tvOS sidebar both read it.
//

import SwiftUI

/// A top-level Settings category — one root row on iOS / macOS, one sidebar
/// entry on tvOS.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case premium, profiles
    case playlists, epg, library
    case home, sports, appearance
    case player, downloads, recordingServer
    case iCloud, connectedServices
    case storage, help, about, developer

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .premium: "Lume Pro"
        case .profiles: "Profiles"
        case .playlists: "Playlists"
        case .epg: "TV Guide"
        case .library: "Library"
        case .home: "Home"
        case .sports: "Sports"
        case .appearance: "Appearance"
        case .player: "Player"
        case .downloads: "Downloads"
        case .recordingServer: "Recording Server"
        case .iCloud: "iCloud"
        case .connectedServices: "Connected Services"
        case .storage: "Storage & Cache"
        case .help: "Help & Feedback"
        case .about: "About"
        case .developer: "Developer"
        }
    }

    var group: SettingsCategoryGroup {
        switch self {
        case .premium, .profiles: .account
        case .playlists, .epg, .library: .content
        case .home, .sports, .appearance: .experience
        case .player, .downloads, .recordingServer: .playback
        case .iCloud, .connectedServices: .sync
        case .storage, .help, .about, .developer: .system
        }
    }

    /// Whether this build and platform offer the category at all. Appearance
    /// and Downloads don't exist on tvOS, and Developer is a DEBUG-only
    /// iOS / macOS tool. Help & Feedback and About are sidebar panes on tvOS
    /// only; iOS / macOS show their rows on the root list itself.
    var isAvailableOnPlatform: Bool {
        switch self {
        case .help, .about:
            #if os(tvOS)
                true
            #else
                false
            #endif
        case .appearance, .downloads:
            #if os(tvOS)
                false
            #else
                true
            #endif
        case .developer:
            #if DEBUG && !SIDE_LOAD && !os(tvOS)
                true
            #else
                false
            #endif
        default:
            true
        }
    }

    /// The categories shown, in order. Connected Services needs credentials
    /// for Trakt or Simkl in this build (OpenSubtitles lives under Player).
    static func visible(hasConnectedServices: Bool) -> [SettingsCategory] {
        allCases.filter { category in
            category.isAvailableOnPlatform && (category != .connectedServices || hasConnectedServices)
        }
    }

    /// `visible(hasConnectedServices:)` split into its groups, empty groups dropped.
    static func grouped(hasConnectedServices: Bool) -> [(group: SettingsCategoryGroup, categories: [SettingsCategory])] {
        let categories = visible(hasConnectedServices: hasConnectedServices)
        return SettingsCategoryGroup.allCases.compactMap { group in
            let members = categories.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// The Lume Pro feature a free user hits on this row: it shows the crown
    /// and opens the paywall instead of the page.
    var lockedFeature: PremiumFeature? {
        switch self {
        case .recordingServer: .recordingServer
        default: nil
        }
    }
}

/// The groups the root list is split into. tvOS separates them with spacing
/// only.
enum SettingsCategoryGroup: CaseIterable {
    case account, content, experience, playback, sync, system

    /// The group header; the first group has none.
    var title: LocalizedStringKey? {
        switch self {
        case .account: nil
        case .content: "Your Content"
        case .experience: "Experience"
        case .playback: "Playback"
        case .sync: "Accounts & Sync"
        case .system: "System"
        }
    }
}

#if !os(tvOS)

    extension SettingsCategory {
        /// The row's SF Symbol, in the same plain accent-tinted `Label` style the
        /// sub-settings pages use.
        var systemImage: String {
            switch self {
            case .premium: "crown"
            case .profiles: "person.crop.circle"
            case .playlists: "tv"
            case .epg: "list.clipboard"
            case .library: "slider.horizontal.3"
            case .home: "house"
            case .sports: "sportscourt"
            case .appearance: "circle.lefthalf.filled"
            case .player: "play.circle"
            case .downloads: "arrow.down.circle"
            case .recordingServer: "record.circle"
            case .iCloud: "icloud"
            case .connectedServices: "arrow.trianglehead.2.clockwise.rotate.90.circle"
            case .storage: "internaldrive"
            case .help: "questionmark.circle"
            case .about: "info.circle"
            case .developer: "hammer"
            }
        }
    }

    /// A root row: the icon and title, and — only where the page behind it is a
    /// single choice, or for the Lume Pro / iCloud status — the current value.
    struct SettingsCategoryRowLabel: View {
        let category: SettingsCategory
        var value: Text?
        var showsPremiumBadge = false

        var body: some View {
            HStack {
                Label(category.title, systemImage: category.systemImage)
                if showsPremiumBadge {
                    PremiumBadge()
                }
                Spacer(minLength: 8)
                if let value {
                    value
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

#endif
