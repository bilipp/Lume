import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Not `private`: read by the SettingsView+Profiles extension (separate file).
    @Environment(ProfileManager.self) var profileManager: ProfileManager?
    // Not `private`: read by the SettingsView+AutoSync extension (separate file).
    @Query var playlists: [Playlist]
    @State private var showingAddPlaylist = false
    @State private var trakt = TraktService.shared
    /// Not `private`: read by the SettingsView+Indexing extension (separate file).
    @State var indexing = ContentIndexingService.shared
    /// Legacy single-engine key, kept in sync with the primary engine so a
    /// downgrade still finds the user's preferred engine, and read as the
    /// migration seed for the priority list. See `PlayerEnginePriority`.
    @AppStorage(PlayerSettings.engineKey) private var engineRaw: String = PlayerEngineKind.defaultValue.rawValue
    @AppStorage(PlayerSettings.enginePriorityKey) private var enginePriorityRaw: String = ""
    @AppStorage(PlayerSettings.externalPlayerKey) private var externalPlayerRaw: String = ""
    @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
    private var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
    @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
    private var showNextEpisodeButton = PlayerSettings.Playback.showNextEpisodeButtonDefault
    @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
    private var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
    /// Not `private`: read by the SettingsView+AutoSync extension (separate file).
    @AppStorage(SyncFrequency.storageKey) var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    #if !os(tvOS)
        @AppStorage(DownloadManager.maxConcurrentKey) private var maxConcurrent = 1
        @AppStorage(DownloadManager.autoDeleteKey) private var autoDeleteAfterWatching = false
    #endif

    #if os(tvOS)
        /// The category whose content is shown in the right pane. Follows focus
        /// in the sidebar (Apple TV Settings behaviour) and persists once focus
        /// moves into the detail pane.
        @State private var selectedCategory: SettingsCategory = .playlists
        @FocusState private var focusedCategory: SettingsCategory?
        /// The playlist drilled into within the Playlists category. When set, its
        /// settings replace the playlist list *in the detail pane* rather than
        /// pushing a full-screen view — a push hides the header tab bar and
        /// strands remote focus once the content scrolls.
        @State private var selectedPlaylist: Playlist?
        /// The engine whose options are drilled into within the Player category,
        /// replacing the player detail in place (same reasoning as `selectedPlaylist`).
        @State private var selectedEngineOptions: PlayerEngineKind?
    #endif

    /// The user's ordered engine fallback list (migrates the legacy single-engine
    /// key on first read). The first entry is the primary engine.
    private var enginePriority: [PlayerEngineKind] {
        PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
    }

    #if os(tvOS)
        /// The primary (most-preferred) engine — its description is shown under
        /// the priority list.
        private var primaryEngine: PlayerEngineKind {
            enginePriority.first ?? .defaultValue
        }

        /// Move the engine at `index` one slot up or down the priority list,
        /// persisting the new order and keeping the legacy single-engine key in
        /// sync with the primary so other readers (and a downgrade) still resolve it.
        private func moveEngine(at index: Int, by offset: Int) {
            var list = enginePriority
            let target = index + offset
            guard list.indices.contains(index), list.indices.contains(target) else { return }
            list.swapAt(index, target)
            let normalized = PlayerEnginePriority.normalized(list)
            enginePriorityRaw = PlayerEnginePriority.encode(normalized)
            engineRaw = normalized.first?.rawValue ?? PlayerEngineKind.defaultValue.rawValue
        }
    #endif

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
                    profilesSection
                    playlistsSection
                    librarySection
                    indexingSection
                    autoSyncSection
                    CloudSyncSection()
                    if trakt.isConfigured {
                        integrationsSection
                    }
                    playbackSection
                    downloadsSection
                    playerSection
                    supportSection
                    aboutSection
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
                        showingAddPlaylist = true
                    } label: {
                        Label("Add Playlist", systemImage: "plus")
                    }
                }
            } header: {
                Text("Playlists")
            } footer: {
                if !playlists.isEmpty {
                    Text("\(playlists.count) playlist\(playlists.count == 1 ? "" : "s")")
                }
            }
        }

        private var librarySection: some View {
            Section {
                NavigationLink {
                    ContentManagementView()
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
                Toggle("Show Next Episode Button", isOn: $showNextEpisodeButton)
                Toggle("Show Skip Intro Button", isOn: $showSkipIntroButton)
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

        private var aboutSection: some View {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "play.tv.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lume")
                        Text("Version 1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }

        private func deletePlaylists(offsets: IndexSet) {
            withAnimation {
                for index in offsets {
                    modelContext.delete(playlists[index])
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
                .defaultFocus($focusedCategory, .playlists)
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
                ContentManagementView()
                    .focusSection()
            default:
                tvDetail
            }
        }

        private var tvDetail: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    switch selectedCategory {
                    case .playlists:
                        if let selectedPlaylist {
                            PlaylistDetailView(playlist: selectedPlaylist) {
                                self.selectedPlaylist = nil
                            }
                        } else {
                            tvPlaylistsDetail
                        }
                    case .profiles: TVProfilesSettingsView()
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

        private var tvPlaylistsDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                tvPlaylistsList
                tvAutoSyncSection
                tvIndexingSection
                TVCloudSyncSection()
            }
        }

        private var tvPlaylistsList: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Playlists")

                if playlists.isEmpty {
                    Text("No playlists yet. Add your IPTV provider to start streaming.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            selectedPlaylist = playlist
                        } label: {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                    Text(playlist.serverURL)
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }
                }

                Button {
                    showingAddPlaylist = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                        Text("Add Playlist")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
            }
        }

        private var tvIntegrationsDetail: some View {
            TVTraktIntegrationView()
        }

        private var tvPlayerDetail: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Playback")
                    TVOptionToggleRow(title: "Autoplay Next Episode", isOn: $autoPlayNext)
                    TVOptionToggleRow(title: "Show Next Episode Button", isOn: $showNextEpisodeButton)
                    TVOptionToggleRow(title: "Show Skip Intro Button", isOn: $showSkipIntroButton)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Engine Priority")

                    VStack(spacing: 2) {
                        ForEach(Array(enginePriority.enumerated()), id: \.element) { index, kind in
                            tvEnginePriorityRow(kind: kind, index: index)
                        }
                    }

                    Text(primaryEngine.subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("External Player")

                    TVOptionCycleRow(
                        title: "External Player",
                        valueLabel: ExternalPlayer(rawValue: externalPlayerRaw)?.displayName
                            ?? String(localized: "Off")
                    ) {
                        externalPlayerRaw = nextExternalPlayerRaw(after: externalPlayerRaw)
                    }

                    Text("Streams open in the selected app instead of Lume's player. Downloads always play in Lume, and the built-in player is used when the app is not installed.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                // Each engine's options live behind a dedicated row, so they're
                // all reachable regardless of the priority order. AVPlayer has no
                // configurable options, so it isn't listed.
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Engine Options")
                    VStack(spacing: 2) {
                        tvEngineOptionsRow(.vlcKit)
                        tvEngineOptionsRow(.ksPlayer)
                    }
                }
            }
        }

        /// A drill-in row that replaces the player detail with the given engine's
        /// options in place. Returning focus to the sidebar (Menu) restores it.
        private func tvEngineOptionsRow(_ engine: PlayerEngineKind) -> some View {
            Button {
                selectedEngineOptions = engine
            } label: {
                HStack(spacing: 16) {
                    Text("\(engine.displayName) Options")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        /// One row of the tvOS engine-priority list: the engine name, a "Primary"
        /// tag on the top entry, and up / down controls that reorder the list.
        private func tvEnginePriorityRow(kind: PlayerEngineKind, index: Int) -> some View {
            HStack(spacing: 16) {
                Text(kind.displayName)
                    .font(.system(size: TVSettingsMetrics.rowFontSize))

                if index == 0 {
                    Text("Primary")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    moveEngine(at: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(index == 0)
                .accessibilityLabel("Move \(kind.displayName) up")

                Button {
                    moveEngine(at: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(index == enginePriority.count - 1)
                .accessibilityLabel("Move \(kind.displayName) down")
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, TVSettingsMetrics.rowVPadding)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

#endif
