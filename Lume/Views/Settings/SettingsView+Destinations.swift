//
//  SettingsView+Destinations.swift
//  Lume
//
//  The pages the iOS/macOS Settings root pushes: one per root row, and one
//  per route another surface can open Settings on.
//

import SwiftUI

#if !os(tvOS)

    /// The page a `SettingsRoute` opens on, pushed above the root.
    struct SettingsRouteDestination: View {
        let route: SettingsRoute

        var body: some View {
            switch route {
            case .playlists: PlaylistsSettingsView()
            case .combinedView: CombinedPlaylistsSettingsView()
            }
        }
    }

    /// The page behind a root Settings row.
    struct SettingsCategoryDestination: View {
        let category: SettingsCategory

        var body: some View {
            switch category {
            case .premium: PremiumPlanView()
            case .profiles: ManageProfilesView()
            case .playlists: PlaylistsSettingsView()
            case .epg: EPGSettingsView()
            case .library: LibrarySettingsView()
            case .home: HomeLayoutSettingsView()
            case .liveTV: LiveTVSettingsView()
            case .sports: SportsSettingsView()
            case .appearance: AppearanceSettingsView()
            case .player: PlayerSettingsView()
            case .downloads: DownloadsSettingsView()
            case .iCloud: SyncSettingsView()
            case .connectedServices: ConnectedServicesView()
            case .storage: StorageManagementView()
            case .help, .about: EmptyView() // inline sections on the root
            case .developer:
                #if DEBUG && !SIDE_LOAD
                    DeveloperSettingsView()
                #else
                    EmptyView()
                #endif
            }
        }
    }

#endif
