//
//  SettingsView+Library.swift
//  Lume
//
//  Library settings, scoped to the active playlist: which content tabs it
//  shows (plus the app-wide Sports tab), Categories & Channels (Content
//  Management, PIN-gated), and whether Search spans every playlist.
//
//  iOS / macOS: `LibrarySettingsView`, pushed from the root row, with the
//  tabs on their own screen (`TabLayoutSettingsView`). tvOS: the
//  Library pane, whose Categories & Channels row drills in place.
//

import SwiftData
import SwiftUI

extension MainTab {
    /// Whether this tab is on in Settings › Library › Tabs, and how to flip
    /// it; nil when it can't be switched (Combined View content tabs, Home
    /// while forced).
    func settingsSwitch(
        scope: CatalogScope,
        activePlaylist: Playlist?,
        homeForced: Bool,
        enabled: (home: Binding<Bool>, sports: Binding<Bool>),
        store: (context: ModelContext, cloudSync: CloudSyncCoordinator?)
    ) -> (isOn: Bool, toggle: (() -> Void)?) {
        switch playlistTab {
        case nil where self == .home:
            let home = enabled.home
            return (home.wrappedValue || homeForced, homeForced ? nil : { home.wrappedValue.toggle() })
        case nil:
            let sports = enabled.sports
            return (sports.wrappedValue, { sports.wrappedValue.toggle() })
        case let playlistTab?:
            if scope.isCombined {
                return (scope.visibleTabs(isolatedHidden: []).contains(playlistTab), nil)
            }
            guard let activePlaylist else { return (false, nil) }
            let binding = activePlaylist.tabVisibility(playlistTab, context: store.context, cloudSync: store.cloudSync)
            return (binding.wrappedValue, { binding.wrappedValue.toggle() })
        }
    }
}

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

#if !os(tvOS)

    struct LibrarySettingsView: View {
        @Query private var playlists: [Playlist]
        @Environment(\.catalogScope) private var catalogScope
        @AppStorage(SearchSettings.searchAllPlaylistsKey)
        private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault
        @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
        private var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault

        var body: some View {
            let scope = catalogScope
            // Content Management is per playlist; in Combined it manages the
            // priority-1 member.
            let activePlaylist = playlists.primaryMember(of: scope)
            List {
                Section {
                    NavigationLink {
                        TabLayoutSettingsView(activePlaylist: activePlaylist)
                    } label: {
                        Text("Tabs")
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
                    Toggle(isOn: $groupDuplicateTitles) {
                        HStack(spacing: 6) {
                            Text("Group Duplicate Titles")
                            BetaBadge()
                        }
                    }
                } footer: {
                    Text("Show a movie or series once when it's in several qualities, languages or playlists, and pick the version when you play it.")
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
            let content = scope.visibleTabs(isolatedHidden: activePlaylist?.hiddenTabs ?? [])
            let homeForced = TabLayoutSettings.homeIsForced(content: content)
            let rows = TabLayoutSettings.listedTabs(
                orderRaw: tabOrderRaw, showsContent: scope.isCombined || activePlaylist != nil
            )
            return VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Tabs")
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element) { index, tab in
                            tvTabRow(
                                tab, rows: rows, index: index,
                                state: tab.settingsSwitch(
                                    scope: scope, activePlaylist: activePlaylist, homeForced: homeForced,
                                    enabled: ($homeTabEnabled, $sportsTabEnabled),
                                    store: (modelContext, cloudSync)
                                )
                            )
                        }
                    }
                    TVOptionResetRow(title: "Reset") {
                        TabLayoutSettings.reset(orderRaw: &tabOrderRaw, homeEnabled: &homeTabEnabled)
                    }
                    .disabled(TabLayoutSettings.isDefault(orderRaw: tabOrderRaw, homeEnabled: homeTabEnabled))
                    tvTabsFooter(scope: scope, activePlaylist: activePlaylist, homeForced: homeForced)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
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
                    TVOptionToggleRow(title: "Group Duplicate Titles", isOn: $groupDuplicateTitles, showsBetaBadge: true)
                    Text("Show a movie or series once when it's in several qualities, languages or playlists, and pick the version when you play it.")
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

        /// One tab row: an on/off control, the tab name, and up / down controls
        /// that reorder the tabs. Mirrors `tvHomeSectionRow`.
        private func tvTabRow(
            _ tab: MainTab,
            rows: [MainTab],
            index: Int,
            state: (isOn: Bool, toggle: (() -> Void)?)
        ) -> some View {
            let name = tab.spokenName
            return TVSettingsReorderRow(
                name: name,
                index: index,
                count: rows.count,
                onMove: { moveTab(in: rows, at: index, by: $0) },
                leading: {
                    Button {
                        state.toggle?()
                    } label: {
                        Image(systemName: state.isOn ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(TVContentIconButtonStyle())
                    .disabled(state.toggle == nil)
                    .accessibilityLabel(state.isOn ? "Hide \(name)" : "Show \(name)")
                    .accessibilityValue(state.isOn ? Text("On") : Text("Off"))

                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.system(size: TVSettingsMetrics.rowFontSize))
                        .foregroundStyle(state.isOn ? .primary : .secondary)
                }
            )
        }

        private func tvTabsFooter(scope: CatalogScope, activePlaylist: Playlist?, homeForced: Bool) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                if scope.isCombined {
                    // swiftlint:disable:next line_length
                    Text("Turn tabs on or off and select the arrows on a row to move it. In Combined View, Movies, Series and Live TV follow each playlist's content types. Home, Sports and the order apply to every playlist.")
                } else if let activePlaylist {
                    // swiftlint:disable:next line_length
                    Text("Turn tabs on or off and select the arrows on a row to move it. Movies, Series and Live TV apply to \(activePlaylist.name), your active playlist. Home, Sports and the order apply to every playlist.")
                }
                ForEach(
                    TabLayoutSettings.footerNotes(
                        homeForced: homeForced, homeEnabled: homeTabEnabled, sportsEnabled: sportsTabEnabled
                    ),
                    id: \.self
                ) { Text($0) }
            }
        }

        private func moveTab(in rows: [MainTab], at index: Int, by offset: Int) {
            var moved = rows
            guard moved.move(at: index, by: offset) else { return }
            tabOrderRaw = TabLayoutSettings.reordered(orderRaw: tabOrderRaw, listed: rows, moved: moved)
        }
    }

#endif
