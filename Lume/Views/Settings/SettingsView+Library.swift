//
//  SettingsView+Library.swift
//  Lume
//
//  Library settings, scoped to the active playlist: which content tabs it
//  shows (plus the app-wide Sports tab), Categories & Channels (Content
//  Management, PIN-gated), and whether Search spans every playlist.
//
//  iOS / macOS: `LibrarySettingsView`, pushed from the root row. tvOS: the
//  Library pane, whose Categories & Channels row drills in place.
//

import SwiftData
import SwiftUI

extension Playlist {
    /// Whether `tab` shows for this playlist, as a switch. Saved straight away
    /// and handed to iCloud sync, so other devices pick the change up too.
    func tabVisibility(
        _ tab: PlaylistTab,
        context: ModelContext,
        cloudSync: CloudSyncCoordinator?
    ) -> Binding<Bool> {
        Binding(
            get: { !self.hiddenTabs.contains(tab) },
            set: { shows in
                var hidden = self.hiddenTabs
                if shows {
                    hidden.remove(tab)
                } else {
                    hidden.insert(tab)
                }
                self.hiddenTabs = hidden
                try? context.save()
                Task { @MainActor in cloudSync?.reconcile() }
            }
        )
    }
}

extension PlaylistTab {
    var title: LocalizedStringKey {
        switch self {
        case .movies: "Movies"
        case .series: "Series"
        case .liveTV: "Live TV"
        }
    }
}

#if !os(tvOS)

    struct LibrarySettingsView: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @Query private var playlists: [Playlist]
        @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
        @AppStorage(SportsSyncService.tabEnabledKey) private var sportsTabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(SearchSettings.searchAllPlaylistsKey)
        private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault

        var body: some View {
            let activePlaylist = playlists.active(for: selectedPlaylistID)
            List {
                Section {
                    if let activePlaylist {
                        ForEach(PlaylistTab.allCases) { tab in
                            Toggle(tab.title, isOn: activePlaylist.tabVisibility(
                                tab, context: modelContext, cloudSync: cloudSync
                            ))
                        }
                    }
                    Toggle("Sports", isOn: $sportsTabEnabled)
                } header: {
                    Text("Tabs")
                } footer: {
                    if let activePlaylist {
                        Text("Movies, Series and Live TV apply to \(activePlaylist.name), your active playlist. Sports applies to every playlist.")
                    }
                }

                Section {
                    NavigationLink {
                        ParentalGateView { ContentManagementView() }
                    } label: {
                        Text("Categories & Channels")
                    }
                    .disabled(activePlaylist == nil)
                } header: {
                    Text("Content")
                } footer: {
                    Text("Hide and reorder categories and channels for the active playlist.")
                }

                Section {
                    Toggle("Search All Playlists", isOn: $searchAllPlaylists)
                } header: {
                    Text("Search")
                } footer: {
                    Text("When off, search only finds content in the active playlist. Turn this on to search across all your playlists.")
                }
            }
            .platformNavigationTitle("Library")
        }
    }

#endif

#if os(tvOS)

    extension SettingsView {
        var tvLibraryDetail: some View {
            let activePlaylist = playlists.active(for: selectedPlaylistID)
            return VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Tabs")
                    if let activePlaylist {
                        ForEach(PlaylistTab.allCases) { tab in
                            TVOptionToggleRow(title: tab.title, isOn: activePlaylist.tabVisibility(
                                tab, context: modelContext, cloudSync: cloudSync
                            ))
                        }
                    }
                    TVOptionToggleRow(title: "Sports", isOn: $sportsTabEnabled)
                    if let activePlaylist {
                        Text("Movies, Series and Live TV apply to \(activePlaylist.name), your active playlist. Sports applies to every playlist.")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                            .padding(.top, 6)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Content")
                    Button {
                        beginContentManagementHandoff()
                        showingContentManagement = true
                    } label: {
                        HStack(spacing: 16) {
                            Text("Categories & Channels")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(activePlaylist == nil)
                    Text("Hide and reorder categories and channels for the active playlist.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Search")
                    TVOptionToggleRow(title: "Search All Playlists", isOn: $searchAllPlaylists)
                    Text("When off, search only finds content in the active playlist. Turn this on to search across all your playlists.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
            }
        }
    }

#endif
