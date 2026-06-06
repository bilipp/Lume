import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var playlists: [Playlist]
    @State private var showingAddPlaylist = false
    @State private var trakt = TraktService.shared
    @AppStorage(PlayerSettings.engineKey) private var engineRaw: String = PlayerEngineKind.defaultValue.rawValue
    @AppStorage(PlayerSettings.deinterlaceKey) private var deinterlace = PlayerSettings.deinterlaceDefault

    #if os(tvOS)
        /// The category whose content is shown in the right pane. Follows focus
        /// in the sidebar (Apple TV Settings behaviour) and persists once focus
        /// moves into the detail pane.
        @State private var selectedCategory: SettingsCategory = .playlists
        @FocusState private var focusedCategory: SettingsCategory?
    #endif

    private var engine: Binding<PlayerEngineKind> {
        Binding(
            get: { PlayerEngineKind(rawValue: engineRaw) ?? .defaultValue },
            set: { engineRaw = $0.rawValue }
        )
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - tvOS (Apple TV Settings-style two-pane layout)

    #if os(tvOS)
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
                    }
                }
                .navigationDestination(for: Playlist.self) { playlist in
                    PlaylistDetailView(playlist: playlist)
                }
                .fullScreenCover(isPresented: $showingAddPlaylist) {
                    LoginView()
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
                    case .playlists: tvPlaylistsDetail
                    case .integrations: tvIntegrationsDetail
                    case .player: tvPlayerDetail
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
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Playlists")

                if playlists.isEmpty {
                    Text("No playlists yet. Add your IPTV provider to start streaming.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
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
                    TVSettingsSectionLabel("Engine")

                    VStack(spacing: 2) {
                        ForEach(PlayerEngineKind.allCases) { kind in
                            Button {
                                engine.wrappedValue = kind
                            } label: {
                                HStack(spacing: 16) {
                                    Text(kind.displayName)
                                    Spacer(minLength: 0)
                                    if engine.wrappedValue == kind {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 24, weight: .semibold))
                                    }
                                }
                            }
                            .buttonStyle(TVSettingsRowButtonStyle())
                        }
                    }

                    Text(engine.wrappedValue.subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Playback")

                    Button {
                        deinterlace.toggle()
                    } label: {
                        HStack(spacing: 16) {
                            Text("Deinterlace Video")
                            Spacer(minLength: 0)
                            Text(deinterlace ? "On" : "Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())

                    Text(tvDeinterlaceFooter)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
            }
        }

        private var tvAboutDetail: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("About")

                HStack(spacing: 18) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 60, height: 60)
                        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lume")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Version 1.0.0")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.vertical, 8)
            }
        }

        private var tvDeinterlaceFooter: String {
            "Smooths interlaced channels (often 1080i). Best left off here — VLC does not support hardware decoding with interlacing. Disabling this can result in stutters for some channels."
        }
    #endif

    // MARK: - iOS / macOS (grouped list)

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                List {
                    playlistsSection
                    librarySection
                    if trakt.isConfigured {
                        integrationsSection
                    }
                    playerSection
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
                    LoginView()
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

        private var playerSection: some View {
            Section {
                Picker("Engine", selection: engine) {
                    ForEach(PlayerEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                Text(engine.wrappedValue.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Deinterlace Video", isOn: $deinterlace)

                Text(deinterlaceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Player")
            }
        }

        private var deinterlaceFooter: String {
            #if os(iOS)
                "Smooths interlaced channels (often 1080i). Best left off here — VLC does not support hardware decoding with interlacing. Disabling this can result in stutters for some channels."
            #else
                "Smooths interlaced channels (often 1080i). Turn off to show frames as-is, which may look combed on motion."
            #endif
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

// MARK: - tvOS settings categories

#if os(tvOS)

    /// The top-level settings categories shown in the tvOS sidebar.
    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case playlists, content, integrations, player, about

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .playlists: "Playlists"
            case .content: "Content"
            case .integrations: "Integrations"
            case .player: "Player"
            case .about: "About"
            }
        }
    }

#endif

#Preview("Empty") {
    SettingsView()
}

#Preview("With Playlists") {
    SettingsView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                let backup = Playlist(name: "Backup", serverURL: "http://backup.com:8080", username: "user2", password: "pass2")
                container.mainContext.insert(playlist)
                container.mainContext.insert(backup)
            }
        }
}
