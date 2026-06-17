import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Not `private`: read by the SettingsView+Profiles extension (separate file).
    @Environment(ProfileManager.self) var profileManager: ProfileManager?
    /// Not `private`: read by the SettingsView+AutoSync extension (separate file).
    @Query var playlists: [Playlist]
    /// Not `private`: read by the SettingsView+Playlists extension (separate file).
    @State var showingAddPlaylist = false
    @State private var trakt = TraktService.shared
    /// Premium entitlement + paywall presentation. Not `private`: read by the
    /// SettingsView+Playlists / +TVComponents extensions (separate files).
    @State var premium = PremiumManager.shared
    @State var showPaywall = false
    @State var paywallHighlight: PremiumFeature?
    /// Not `private`: read by the SettingsView+Indexing extension (separate file).
    @State var indexing = ContentIndexingService.shared
    /// Legacy single-engine key, kept in sync with the primary engine so a
    /// downgrade still finds the user's preferred engine, and read as the
    /// migration seed for the priority list. See `PlayerEnginePriority`.
    /// Not `private`: engine / playback preferences are read by the
    /// SettingsView+TVPlayer extension (separate file, tvOS player pane).
    @AppStorage(PlayerSettings.engineKey) var engineRaw: String = PlayerEngineKind.defaultValue.rawValue
    @AppStorage(PlayerSettings.enginePriorityKey) var enginePriorityRaw: String = ""
    @AppStorage(PlayerSettings.externalPlayerKey) var externalPlayerRaw: String = ""
    @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
    var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
    @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
    var showNextEpisodeButton = PlayerSettings.Playback.showNextEpisodeButtonDefault
    @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
    var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
    @AppStorage(SearchSettings.searchAllPlaylistsKey)
    private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault
    /// Not `private`: read by the SettingsView+AutoSync extension (separate file).
    @AppStorage(SyncFrequency.storageKey) var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    #if !os(tvOS)
        @AppStorage(DownloadManager.maxConcurrentKey) private var maxConcurrent = 1
        @AppStorage(DownloadManager.autoDeleteKey) private var autoDeleteAfterWatching = false
    #endif

    #if os(tvOS)
        /// The globally-selected playlist, shared with the content tabs. tvOS has
        /// no toolbar switcher, so the Playlists settings pane is where the active
        /// playlist is chosen. Not `private`: read by the SettingsView+Playlists
        /// extension (separate file).
        @AppStorage(PlaylistSelectionStore.key) var selectedPlaylistID: String = ""
        /// Routes the switch through the blocking overlay (see PlaylistSwitchModel).
        /// Not `private`: read by the SettingsView+Playlists extension.
        @Environment(PlaylistSwitchModel.self) var playlistSwitch: PlaylistSwitchModel?
        /// The category whose content is shown in the right pane. Follows focus
        /// in the sidebar (Apple TV Settings behaviour) and persists once focus
        /// moves into the detail pane.
        @State private var selectedCategory: SettingsCategory = .premium
        @FocusState private var focusedCategory: SettingsCategory?
        /// The playlist drilled into within the Playlists category. When set, its
        /// settings replace the playlist list *in the detail pane* rather than
        /// pushing a full-screen view — a push hides the header tab bar and
        /// strands remote focus once the content scrolls. Not `private`: read by
        /// the SettingsView+Playlists extension (separate file).
        @State var selectedPlaylist: Playlist?
        /// The engine whose options are drilled into within the Player category,
        /// replacing the player detail in place (same reasoning as `selectedPlaylist`).
        /// Not `private`: read by the SettingsView+TVPlayer extension (separate file).
        @State var selectedEngineOptions: PlayerEngineKind?
    #endif

    /// The user's ordered engine fallback list (migrates the legacy single-engine
    /// key on first read). The first entry is the primary engine. Not `private`:
    /// read by the SettingsView+TVPlayer extension (separate file).
    var enginePriority: [PlayerEngineKind] {
        PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - iOS / macOS (grouped list)

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                List {
                    premiumStatusSection
                    profilesSection
                    playlistsSection
                    librarySection
                    searchSection
                    indexingSection
                    autoSyncSection
                    CloudSyncSection()
                    if trakt.isConfigured {
                        integrationsSection
                    }
                    playbackSection
                    downloadsSection
                    playerSection
                    storageSection
                    supportSection
                    aboutSection
                    #if DEBUG && !SIDE_LOAD
                        developerSection
                    #endif
                }
                #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
                .platformNavigationTitle("Settings")
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .sheet(isPresented: $showingAddPlaylist) {
                    LoginView(isModal: true)
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 600)
            #endif
        }

        private var playlistsSection: some View {
            Section {
                if playlists.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("No Playlists")
                                .foregroundStyle(.secondary)
                            Button("Add Playlist") {
                                showingAddPlaylist = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "tv")
                                    .foregroundStyle(.secondary)
                                    .font(.body)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(playlist.name)
                                    Text(playlist.serverURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .onDelete(perform: deletePlaylists)

                    Button {
                        if canAddPlaylist {
                            showingAddPlaylist = true
                        } else {
                            presentPaywall(.multiplePlaylists)
                        }
                    } label: {
                        Label("Add Playlist", systemImage: canAddPlaylist ? "plus" : "crown")
                    }
                }
            } header: {
                Text("Playlists")
            } footer: {
                if playlists.isEmpty {
                    EmptyView()
                } else if premium.isPremium {
                    Text("\(playlists.count) playlist\(playlists.count == 1 ? "" : "s")")
                } else {
                    Text("Free includes one playlist. Upgrade to Lume Pro to add more.")
                }
            }
        }

        private var librarySection: some View {
            Section {
                NavigationLink {
                    ParentalGateView { ContentManagementView() }
                } label: {
                    Label("Content Management", systemImage: "slider.horizontal.3")
                }
                .disabled(playlists.isEmpty)
            } header: {
                Text("Library")
            } footer: {
                Text("Hide and reorder categories and channels for the active playlist.")
            }
        }

        private var searchSection: some View {
            Section {
                Toggle("Search All Playlists", isOn: $searchAllPlaylists)
            } header: {
                Text("Search")
            } footer: {
                Text("When off, search only finds content in the active playlist. Turn this on to search across all your playlists.")
            }
        }

        private var integrationsSection: some View {
            Section {
                NavigationLink {
                    TraktIntegrationView()
                } label: {
                    HStack {
                        Label("Trakt", systemImage: "rectangle.stack.badge.play")
                        Spacer()
                        if trakt.isConnected {
                            Text(trakt.username.map { "@\($0)" } ?? "Connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text("Sync watched movies and episodes, and show your Trakt watchlist on Home.")
            }
        }

        private var playbackSection: some View {
            Section {
                Toggle("Autoplay Next Episode", isOn: $autoPlayNext)
                    .disabled(!premium.isPremium)
                Toggle("Show Next Episode Button", isOn: $showNextEpisodeButton)
                    .disabled(!premium.isPremium)
                Toggle("Show Skip Intro Button", isOn: $showSkipIntroButton)
                    .disabled(!premium.isPremium)
                if !premium.isPremium {
                    Button {
                        presentPaywall(.playbackControls)
                    } label: {
                        Label("Unlock with Premium", systemImage: "crown")
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Automatically start the next episode when one finishes, and show a button near the end to skip ahead.")
            }
        }

        private var downloadsSection: some View {
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Manage Downloads", systemImage: "arrow.down.circle")
                }

                Stepper(
                    "Max Simultaneous Downloads: \(maxConcurrent)",
                    value: $maxConcurrent,
                    in: 1 ... 5
                )

                Toggle("Auto-Delete After Watching", isOn: $autoDeleteAfterWatching)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Download movies and episodes for offline playback. Auto-delete removes the file once you've finished watching.")
            }
        }

        private var playerSection: some View {
            Section {
                NavigationLink {
                    PlayerEnginePriorityView()
                } label: {
                    HStack {
                        Text("Player Engines")
                        Spacer()
                        Text(enginePriority.map(\.displayName).joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                NavigationLink("VLCKit Options") { VLCEngineSettingsScreen() }
                NavigationLink("KSPlayer Options") { KSEngineSettingsScreen() }

                Picker("External Player", selection: $externalPlayerRaw) {
                    Text("Off").tag("")
                    ForEach(ExternalPlayer.allCases) { player in
                        Text(player.displayName).tag(player.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Player")
            } footer: {
                Text("Lume plays each stream with your preferred engine and falls back to the next if it can't be played. Streams open in the selected external app instead, when one is installed.")
            }
        }

        private var storageSection: some View {
            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label("Storage & Cache", systemImage: "internaldrive")
                }
            } header: {
                Text("Storage")
            }
        }

        private func deletePlaylists(offsets: IndexSet) {
            withAnimation {
                for index in offsets {
                    PlaylistDeletion.delete(playlists[index], in: modelContext)
                }
            }
        }
    #endif
}

// MARK: - tvOS (Apple TV Settings-style two-pane layout)

#if os(tvOS)

    extension SettingsView {
        private var tvBody: some View {
            NavigationStack {
                HStack(spacing: 0) {
                    tvSidebar
                    tvDetailContainer
                }
                .tvSettingsBackground()
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .defaultFocus($focusedCategory, .premium)
                .onChange(of: focusedCategory) { _, newValue in
                    // Follow focus so the detail pane mirrors the highlighted
                    // category. Ignore nil (focus moved into the detail pane),
                    // which keeps the current selection visible.
                    if let newValue {
                        selectedCategory = newValue
                        // Returning focus to the sidebar leaves any drilled-in
                        // detail (a playlist, or an engine's options), so the
                        // pane reverts to its top-level list.
                        selectedPlaylist = nil
                        selectedEngineOptions = nil
                    }
                }
                .fullScreenCover(isPresented: $showingAddPlaylist) {
                    LoginView(isModal: true)
                }
            }
        }

        private var tvSidebar: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 38, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.bottom, 28)

                VStack(spacing: 2) {
                    ForEach(availableCategories) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TVSettingsSidebarButtonStyle(isSelected: selectedCategory == category))
                        .focused($focusedCategory, equals: category)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 320, alignment: .leading)
            .padding(.leading, 60)
            .padding(.trailing, 24)
            .padding(.vertical, 72)
            .focusSection()
        }

        /// The sidebar categories. Integrations is hidden unless the build has
        /// Trakt credentials configured.
        private var availableCategories: [SettingsCategory] {
            SettingsCategory.allCases.filter { $0 != .integrations || trakt.isConfigured }
        }

        /// Content Management brings its own scroll/background, so it replaces the
        /// detail pane wholesale rather than nesting inside the scrolling detail.
        @ViewBuilder
        private var tvDetailContainer: some View {
            switch selectedCategory {
            case .content:
                ParentalGateView { ContentManagementView() }
                    .focusSection()
            default:
                tvDetail
            }
        }

        private var tvDetail: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    switch selectedCategory {
                    case .premium:
                        tvPremiumDetail
                    case .playlists:
                        if let selectedPlaylist {
                            PlaylistDetailView(playlist: selectedPlaylist) {
                                self.selectedPlaylist = nil
                            }
                        } else {
                            tvPlaylistsDetail
                        }
                    case .profiles: TVProfilesSettingsView()
                    case .search: tvSearchDetail
                    case .storage: StorageManagementView()
                    case .integrations: tvIntegrationsDetail
                    case .player:
                        if let selectedEngineOptions {
                            tvEngineOptionsDetail(for: selectedEngineOptions)
                        } else {
                            tvPlayerDetail
                        }
                    case .about: tvAboutDetail
                    case .content: EmptyView() // handled by tvDetailContainer
                    }
                }
                .frame(maxWidth: TVSettingsMetrics.detailMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
            }
            .focusSection()
        }

        private var tvIntegrationsDetail: some View {
            TVTraktIntegrationView()
        }

        private var tvSearchDetail: some View {
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

#endif
