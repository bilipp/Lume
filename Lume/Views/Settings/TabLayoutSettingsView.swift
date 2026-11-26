#if !os(tvOS)

    import SwiftData
    import SwiftUI

    /// Tab layout settings (iOS / macOS / visionOS): switch each tab on or off
    /// and drag to reorder them. Movies, Series and Live TV belong to the
    /// active playlist; Home, Sports and the order are device-wide. See
    /// `TabLayoutSettings`.
    struct TabLayoutSettingsView: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        /// The playlist Movies, Series and Live TV belong to; in Combined, its
        /// priority-1 member.
        let activePlaylist: Playlist?
        @Environment(\.catalogScope) private var catalogScope
        @AppStorage(SportsSyncService.tabEnabledKey) private var sportsTabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(TabLayoutSettings.orderKey) private var tabOrderRaw = ""
        @AppStorage(TabLayoutSettings.homeEnabledKey) private var homeTabEnabled = TabLayoutSettings.homeEnabledDefault

        var body: some View {
            let scope = catalogScope
            let content = scope.visibleTabs(isolatedHidden: activePlaylist?.hiddenTabs ?? [])
            let homeForced = TabLayoutSettings.homeIsForced(content: content)
            let rows = TabLayoutSettings.listedTabs(
                orderRaw: tabOrderRaw, showsContent: scope.isCombined || activePlaylist != nil
            )
            List {
                Section {
                    ForEach(rows) { tab in
                        tabToggle(tab, scope: scope, activePlaylist: activePlaylist, homeForced: homeForced)
                    }
                    .onMove { offsets, destination in
                        move(rows: rows, from: offsets, to: destination)
                    }
                    Button("Reset") {
                        TabLayoutSettings.reset(orderRaw: &tabOrderRaw, homeEnabled: &homeTabEnabled)
                    }
                    .buttonStyle(.borderless)
                    .disabled(TabLayoutSettings.isDefault(orderRaw: tabOrderRaw, homeEnabled: homeTabEnabled))
                } footer: {
                    tabsFooter(scope: scope, activePlaylist: activePlaylist, homeForced: homeForced)
                }
            }
            .platformNavigationTitle("Tabs")
            .alwaysEditing()
        }

        private func tabToggle(
            _ tab: MainTab,
            scope: CatalogScope,
            activePlaylist: Playlist?,
            homeForced: Bool
        ) -> some View {
            let state = tab.settingsSwitch(
                scope: scope, activePlaylist: activePlaylist, homeForced: homeForced,
                enabled: ($homeTabEnabled, $sportsTabEnabled),
                store: (modelContext, cloudSync)
            )
            return Toggle(tab.title, isOn: Binding(
                get: { state.isOn },
                set: { if $0 != state.isOn { state.toggle?() } }
            ))
            .disabled(state.toggle == nil)
        }

        private func tabsFooter(scope: CatalogScope, activePlaylist: Playlist?, homeForced: Bool) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                if scope.isCombined {
                    // swiftlint:disable:next line_length
                    Text("Turn tabs on or off and drag to reorder them. In Combined View, Movies, Series and Live TV follow each playlist's content types. Home, Sports and the order apply to every playlist.")
                } else if let activePlaylist {
                    // swiftlint:disable:next line_length
                    Text("Turn tabs on or off and drag to reorder them. Movies, Series and Live TV apply to \(activePlaylist.name), your active playlist. Home, Sports and the order apply to every playlist.")
                }
                ForEach(
                    TabLayoutSettings.footerNotes(
                        homeForced: homeForced, homeEnabled: homeTabEnabled, sportsEnabled: sportsTabEnabled
                    ),
                    id: \.self
                ) { Text($0) }
                #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Text("The first tabs appear in the tab bar; the rest move to More.")
                    }
                #endif
            }
        }

        private func move(rows: [MainTab], from offsets: IndexSet, to destination: Int) {
            var moved = rows
            moved.move(fromOffsets: offsets, toOffset: destination)
            tabOrderRaw = TabLayoutSettings.reordered(orderRaw: tabOrderRaw, listed: rows, moved: moved)
        }
    }

    private extension View {
        /// Keeps the tab rows draggable without an Edit button; toggles stay
        /// interactive. macOS lists make `onMove` rows draggable on their own.
        func alwaysEditing() -> some View {
            #if os(iOS) || os(visionOS)
                environment(\.editMode, .constant(.active))
            #else
                self
            #endif
        }
    }

    #Preview {
        NavigationStack {
            TabLayoutSettingsView(activePlaylist: nil)
        }
    }

#endif
