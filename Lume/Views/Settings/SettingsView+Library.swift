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

    /// Whether this playlist is in Combined View, as a switch: including it
    /// contributes every type. Saved and handed to iCloud sync like
    /// `tabVisibility`.
    func combinedInclusion(
        among playlists: [Playlist],
        context: ModelContext,
        cloudSync: CloudSyncCoordinator?
    ) -> Binding<Bool> {
        Binding(
            get: { self.isCombinedMember },
            set: { included in
                self.setCombinedTabs(
                    included ? Set(PlaylistTab.allCases) : [],
                    among: playlists,
                    context: context,
                    cloudSync: cloudSync
                )
            }
        )
    }

    /// Whether this playlist contributes `tab` to Combined View, as a switch.
    func combinedContribution(
        _ tab: PlaylistTab,
        among playlists: [Playlist],
        context: ModelContext,
        cloudSync: CloudSyncCoordinator?
    ) -> Binding<Bool> {
        Binding(
            get: { self.combinedTabs.contains(tab) },
            set: { contributes in
                var tabs = self.combinedTabs
                if contributes {
                    tabs.insert(tab)
                } else {
                    tabs.remove(tab)
                }
                self.setCombinedTabs(tabs, among: playlists, context: context, cloudSync: cloudSync)
            }
        )
    }

    /// No types left means out of Combined View. The priority stays so
    /// re-including restores the slot; a first inclusion goes last.
    private func setCombinedTabs(
        _ tabs: Set<PlaylistTab>,
        among playlists: [Playlist],
        context: ModelContext,
        cloudSync: CloudSyncCoordinator?
    ) {
        if !tabs.isEmpty, combinedPriority == nil {
            combinedPriority = (playlists.compactMap(\.combinedPriority).max() ?? -1) + 1
        }
        combinedTabs = tabs
        try? context.save()
        Task { @MainActor in cloudSync?.reconcile() }
    }
}

extension [Playlist] {
    /// Stamps this order as the Combined View priority, then saves and hands
    /// it to iCloud sync.
    func commitCombinedPriority(context: ModelContext, cloudSync: CloudSyncCoordinator?) {
        for (priority, playlist) in enumerated() where playlist.combinedPriority != priority {
            playlist.combinedPriority = priority
        }
        try? context.save()
        Task { @MainActor in cloudSync?.reconcile() }
    }
}

extension PlaylistTab {
    var title: LocalizedStringKey {
        LocalizedStringKey(spokenName)
    }
}

private func libraryTabsFooter(_ scope: CatalogScope, activePlaylist: Playlist?) -> LocalizedStringKey? {
    if scope.isCombined {
        return "In Combined View, Movies, Series and Live TV follow each playlist's content types. Sports applies to every playlist."
    }
    guard let activePlaylist else { return nil }
    return "Movies, Series and Live TV apply to \(activePlaylist.name), your active playlist. Sports applies to every playlist."
}

#if !os(tvOS)

    struct LibrarySettingsView: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @Query private var playlists: [Playlist]
        @Environment(\.catalogScope) private var catalogScope
        @AppStorage(SportsSyncService.tabEnabledKey) private var sportsTabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(SearchSettings.searchAllPlaylistsKey)
        private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault

        var body: some View {
            let scope = catalogScope
            // Content Management is per playlist; in Combined it manages the
            // priority-1 member.
            let activePlaylist = playlists.primaryMember(of: scope)
            List {
                Section {
                    if scope.isCombined {
                        let combinedTabs = scope.visibleTabs(isolatedHidden: [])
                        ForEach(PlaylistTab.allCases) { tab in
                            Toggle(tab.title, isOn: .constant(combinedTabs.contains(tab)))
                                .disabled(true)
                        }
                    } else if let activePlaylist {
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
                    if let footer = libraryTabsFooter(scope, activePlaylist: activePlaylist) {
                        Text(footer)
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
            let scope = catalogScope
            // Content Management is per playlist; in Combined it manages the
            // priority-1 member.
            let activePlaylist = playlists.primaryMember(of: scope)
            return VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Tabs")
                    if scope.isCombined {
                        let combinedTabs = scope.visibleTabs(isolatedHidden: [])
                        ForEach(PlaylistTab.allCases) { tab in
                            TVOptionToggleRow(title: tab.title, isOn: .constant(combinedTabs.contains(tab)))
                                .disabled(true)
                        }
                    } else if let activePlaylist {
                        ForEach(PlaylistTab.allCases) { tab in
                            TVOptionToggleRow(title: tab.title, isOn: activePlaylist.tabVisibility(
                                tab, context: modelContext, cloudSync: cloudSync
                            ))
                        }
                    }
                    TVOptionToggleRow(title: "Sports", isOn: $sportsTabEnabled)
                    if let footer = libraryTabsFooter(scope, activePlaylist: activePlaylist) {
                        Text(footer)
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
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .focused($drillInFocus, equals: .contentManagement)
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
