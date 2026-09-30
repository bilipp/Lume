import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Not `private`: read by the SettingsView+Library extension (separate file).
    @Environment(CloudSyncCoordinator.self) var cloudSync: CloudSyncCoordinator?
    /// Not `private`: read by the SettingsView+Playlists / +Library extensions (separate files).
    @Query var playlists: [Playlist]
    @State private var trakt = TraktService.shared
    @State private var simkl = SimklService.shared
    /// Premium entitlement + paywall presentation. Not `private`: read by the
    /// SettingsView+Premium / +Playlists / +TVPlayer extensions (separate files).
    @State var premium = PremiumManager.shared
    @State var showPaywall = false
    @State var paywallHighlight: PremiumFeature?
    /// The globally-selected playlist, shared with the content tabs. Library's
    /// tab switches apply to it, and on tvOS (no toolbar switcher) the Playlists
    /// pane is also where it is chosen, the Play/Pause quick-switch overlay the
    /// fast path. Not `private`: read by the SettingsView+Playlists / +Library
    /// extensions (separate files).
    @AppStorage(PlaylistSelectionStore.key) var selectedPlaylistID: String = ""
    #if !os(tvOS)
        /// The app-wide appearance override (System / Dark / Light), shown as the
        /// Appearance row's value. Not offered on tvOS — the TV UI is designed
        /// dark and a per-app light mode makes no sense there.
        @AppStorage(AppAppearance.storageKey)
        private var appearanceRaw = AppAppearance.defaultValue.rawValue
    #endif

    #if os(tvOS)
        /// Legacy single-engine key, kept in sync with the primary engine so a
        /// downgrade still finds the user's preferred engine, and read as the
        /// migration seed for the priority list. See `PlayerEnginePriority`.
        /// Not `private`: engine / playback preferences are read by the
        /// SettingsView+TVPlayer extension (separate file, tvOS player pane).
        @AppStorage(PlayerSettings.engineKey) var engineRaw: String = PlayerEngineKind.defaultValue.rawValue
        @AppStorage(PlayerSettings.enginePriorityKey) var enginePriorityRaw: String = ""
        @AppStorage(PlayerSettings.externalPlayerKey) var externalPlayerRaw: String = ""
        @AppStorage(PlayerSettings.externalPlayerScopeKey)
        var externalPlayerScopeRaw: String = ExternalPlayerScope.default.rawValue
        @AppStorage(PlayerSettings.liveSurfModeKey)
        var liveSurfModeRaw: String = LiveSurfMode.default.rawValue
        @AppStorage(PlayerSettings.tvRemoteSwipesKey)
        var tvRemoteSwipes = PlayerSettings.tvRemoteSwipesDefault
        @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
        var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
        /// tvOS only: off tvOS the transport row carries an always-available
        /// Next Episode button, so `PlayerNextUpOverlay`'s outro-armed one —
        /// and with it this switch — has nothing left to control.
        @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
        var showNextEpisodeButton = PlayerSettings.Playback.showNextEpisodeButtonDefault
        @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
        var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
        /// Comma-separated preferred languages, empty meaning no preference (see `PreferredLanguageList`).
        @AppStorage(PlayerSettings.Language.preferredAudioLanguagesKey)
        var preferredAudioLanguagesRaw = PlayerSettings.Language.preferredAudioLanguagesDefault
        @AppStorage(PlayerSettings.StreamInfo.detailLevelKey)
        var streamInfoDetailLevelRaw = PlayerSettings.StreamInfo.detailLevelDefault.rawValue
        /// Not `private`: read by the SettingsView+Library extension (separate file).
        @AppStorage(SearchSettings.searchAllPlaylistsKey)
        var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault
        @AppStorage(SportsSyncService.tabEnabledKey) var sportsTabEnabled = SportsSyncService.tabEnabledDefault
        /// Not `private`: read by the SettingsView+AutoSync extension (separate file).
        @AppStorage(SyncFrequency.storageKey) var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue

        /// Routes the switch through the blocking overlay (see PlaylistSwitchModel).
        /// Not `private`: read by the SettingsView+Playlists extension.
        @Environment(PlaylistSwitchModel.self) var playlistSwitch: PlaylistSwitchModel?
        /// Not `private`: the Add Playlist row (SettingsView+Playlists) presents it.
        @State var showingAddPlaylist = false
        /// The category whose content is shown in the right pane. Follows focus
        /// in the sidebar (Apple TV Settings behaviour) and persists once focus
        /// moves into the detail pane.
        @State private var selectedCategory: SettingsCategory = .profiles
        @FocusState private var focusedCategory: SettingsCategory?
        /// The playlist drilled into within the Playlists category. When set, its
        /// settings replace the playlist list *in the detail pane* rather than
        /// pushing a full-screen view — a push hides the header tab bar and
        /// strands remote focus once the content scrolls. Not `private`: read by
        /// the SettingsView+Playlists extension (separate file).
        @State var selectedPlaylist: Playlist?
        /// Whether Library's Categories & Channels is drilled into, replacing the
        /// whole detail pane (same reasoning as `selectedPlaylist`). Not
        /// `private`: set by the SettingsView+Library extension (separate file).
        @State var showingContentManagement = false
        /// Focus handle on the Content Management pane, written once the pane
        /// has replaced the Library detail (see `beginContentManagementHandoff`).
        @FocusState private var contentManagementFocused: Bool
        /// Open while Content Management is taking over the pane — the drill-in
        /// itself, or the PIN pad giving way to it — until focus lands in it.
        /// See `beginContentManagementHandoff`.
        @State private var contentManagementHandoff = false
        /// Draws the sidebar unfocused through the handoff and a beat past it.
        /// Outlives `contentManagementHandoff` because focus leaving the sidebar
        /// reaches `focusedCategory` a render before the row's own `isFocused`:
        /// unmasking on that same render would flash Profiles.
        @State private var sidebarFocusMasked = false
        @State private var contentManagementHandoffTimeout: Task<Void, Never>?
        @State private var sidebarFocusUnmask: Task<Void, Never>?
        /// Whether focus is anywhere in the detail pane. Together with
        /// `focusedCategory` it tells whether focus is outside Settings — up in
        /// the tab bar — which is when `tvTabBarEntryCatcher` takes it.
        @FocusState private var detailFocused: Bool
        @FocusState private var tabBarEntryFocused: Bool
        /// Whether the Player category is drilled into Engines — the priority
        /// list and the per-engine option rows — in place. Not `private`: read
        /// by the SettingsView+TVPlayer extension (separate file).
        @State var showingEngines = false
        /// Whether the Player category is drilled into OpenSubtitles in place.
        /// Not `private`: set by the SettingsView+TVPlayer extension (separate file).
        @State var showingOpenSubtitles = false
        /// The engine whose options are drilled into from Engines, replacing it
        /// in place (same reasoning as `selectedPlaylist`). Not `private`: read by
        /// the SettingsView+TVPlayer extension (separate file).
        @State var selectedEngineOptions: PlayerEngineKind?
        /// Which preferred-language pane is drilled into within the Player
        /// category — the ordered list, or its add picker one level deeper —
        /// replacing the player detail in place (same reasoning as
        /// `selectedEngineOptions`). Not `private`: read by the
        /// SettingsView+TVPlayer extension (separate file).
        @State var preferredLanguagePane: PreferredLanguagePane?

        enum PreferredLanguagePane {
            case list, add
        }

        /// Home layout preferences, shown in the Home category. Not `private`: read
        /// by the SettingsView+TVHome extension (separate file). The iOS/macOS build
        /// has its own `HomeLayoutSettingsView`, so these live in the tvOS block.
        @AppStorage(RecommendationSettings.enabledKey) var recommendationsEnabled = RecommendationSettings.enabledDefault
        @AppStorage(HomeLayoutSettings.sectionOrderKey) var homeSectionOrderRaw = ""
        @AppStorage(HomeLayoutSettings.disabledSectionsKey) var homeDisabledSectionsRaw = ""

        /// The user's ordered engine fallback list (migrates the legacy single-engine
        /// key on first read). The first entry is the primary engine. Not `private`:
        /// read by the SettingsView+TVPlayer extension (separate file).
        var enginePriority: [PlayerEngineKind] {
            PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
        }
    #endif

    /// Whether this build has credentials for any Connected Services entry.
    private var hasConnectedServices: Bool {
        trakt.isConfigured || simkl.isConfigured
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
                    ForEach(SettingsCategory.grouped(hasConnectedServices: hasConnectedServices), id: \.group) { entry in
                        Section {
                            ForEach(entry.categories) { category in
                                row(for: category)
                            }
                        } header: {
                            if let title = entry.group.title {
                                Text(title)
                            }
                        }
                    }
                    HelpFeedbackSection()
                    AboutSection()
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
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 600)
            #endif
        }

        @ViewBuilder
        private func row(for category: SettingsCategory) -> some View {
            if category == .premium, !premium.isPremium {
                // The free plan's row opens the paywall itself rather than a
                // page that would only repeat it.
                Button {
                    presentPaywall(nil)
                } label: {
                    HStack(spacing: 8) {
                        SettingsCategoryRowLabel(category: category, value: Text("Free"))
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    SettingsCategoryDestination(category: category)
                } label: {
                    SettingsCategoryRowLabel(category: category, value: value(for: category))
                }
            }
        }

        /// The trailing value: only for single-choice pages, plus the Lume Pro
        /// and iCloud status.
        private func value(for category: SettingsCategory) -> Text? {
            switch category {
            case .premium:
                Text(premium.isPremium ? "Pro" : "Free")
            case .appearance:
                Text((AppAppearance(rawValue: appearanceRaw) ?? .defaultValue).title)
            case .iCloud:
                cloudSync.map { Text(CloudSyncStatusText.summary($0.status)) }
            default:
                nil
            }
        }
    #endif
}

#if !os(tvOS)

    /// The page behind a root Settings row.
    private struct SettingsCategoryDestination: View {
        let category: SettingsCategory

        var body: some View {
            switch category {
            case .premium: PremiumPlanView()
            case .profiles: ManageProfilesView()
            case .playlists: PlaylistsSettingsView()
            case .epg: EPGSettingsView()
            case .library: LibrarySettingsView()
            case .home: HomeLayoutSettingsView()
            case .sports: SportsSettingsView()
            case .appearance: AppearanceSettingsView()
            case .player: PlayerSettingsView()
            case .downloads: DownloadsSettingsView()
            case .iCloud: CloudSyncSettingsView()
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

// MARK: - tvOS (Apple TV Settings-style two-pane layout)

#if os(tvOS)

    extension SettingsView {
        private var tvBody: some View {
            NavigationStack {
                HStack(spacing: 0) {
                    tvSidebar
                    tvDetailContainer
                        .focused($detailFocused)
                }
                .overlay(alignment: .top) { tvTabBarEntryCatcher }
                .tvSettingsBackground()
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .defaultFocus($focusedCategory, .profiles)
                .onChange(of: focusedCategory) { _, newValue in
                    // The sidebar landing a swap's orphaned focus, not the user
                    // coming back to it: pass it on into Content Management.
                    // It closes once focus has really left the sidebar again —
                    // not when the write below lands, which runs ahead of the
                    // engine.
                    if contentManagementHandoff {
                        if newValue == nil {
                            endContentManagementHandoff()
                        } else {
                            Task { @MainActor in contentManagementFocused = true }
                        }
                        return
                    }
                    // Follow focus so the detail pane mirrors the highlighted
                    // category. Ignore nil (focus moved into the detail pane),
                    // which keeps the current selection visible.
                    if let newValue {
                        selectedCategory = newValue
                        // Returning focus to the sidebar leaves any drilled-in
                        // detail (a playlist, Categories & Channels, Engines or
                        // an engine's options), so the pane reverts to its
                        // top-level list.
                        selectedPlaylist = nil
                        showingContentManagement = false
                        showingEngines = false
                        showingOpenSubtitles = false
                        selectedEngineOptions = nil
                        preferredLanguagePane = nil
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

                // Groups are set apart by spacing alone; the sidebar has no
                // headers or icons, like the Apple TV Settings app.
                VStack(spacing: 14) {
                    ForEach(SettingsCategory.grouped(hasConnectedServices: hasConnectedServices), id: \.group) { entry in
                        VStack(spacing: 2) {
                            ForEach(entry.categories) { category in
                                Button {
                                    selectedCategory = category
                                } label: {
                                    Text(category.title)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                // Focus only passes through here during the
                                // handoff; drawing it would flash Profiles.
                                .buttonStyle(TVSettingsSidebarButtonStyle(
                                    isSelected: selectedCategory == category,
                                    suppressesFocus: sidebarFocusMasked
                                ))
                                .focused($focusedCategory, equals: category)
                            }
                        }
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

        /// Pressing down from the tab bar lands on whatever sits under the
        /// Settings tab — the detail pane's top row (Profiles' first edit
        /// button), never the sidebar, which is far off to the left. This
        /// invisible full-width strip across the top is nearer than any of
        /// them, so it catches that move and hands it to the selected sidebar
        /// category. It's focusable only while focus is outside Settings, so
        /// moving up from the panes still reaches the tab bar.
        private var tvTabBarEntryCatcher: some View {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .focusable(focusedCategory == nil && !detailFocused)
                .focused($tabBarEntryFocused)
                .onChange(of: tabBarEntryFocused) { _, isFocused in
                    guard isFocused else { return }
                    // Same-frame focus writes from a focus callback get dropped.
                    Task { @MainActor in focusedCategory = selectedCategory }
                }
                // Just below the tab bar, which overlaps this overlay's top
                // by ~60 pt, and above the panes' first rows (72 pt top
                // padding). Measured on tvOS 26.5: y ≈ 130 between a tab bar
                // ending at 114 and the first detail row at 157.
                .padding(.top, 77)
        }

        /// Content Management brings its own scroll/background, so it replaces the
        /// detail pane wholesale rather than nesting inside the scrolling detail.
        @ViewBuilder
        private var tvDetailContainer: some View {
            if selectedCategory == .library, showingContentManagement {
                ParentalGateView {
                    ContentManagementView()
                        .onAppear(perform: beginContentManagementHandoff)
                }
                .focusSection()
                .focused($contentManagementFocused)
            } else {
                tvDetail
            }
        }

        /// Replacing the pane wholesale removes the focused view with the
        /// scroll view around it — the Categories & Channels row, or the PIN
        /// pad once it unlocks — and the engine then drops focus on the
        /// sidebar's default (Profiles). Left alone, the sidebar's focus handler
        /// would take that for the user leaving and undo the drill-in on the
        /// spot. The handoff forwards that focus into the pane and, until it
        /// lands there, draws the sidebar unfocused so Profiles never flashes.
        /// It closes once focus arrives, or after half a second at most, so a
        /// swap that keeps its focus can't swallow the user's own later move
        /// to the sidebar. Not `private`: the Library pane's row calls it
        /// (SettingsView+Library).
        func beginContentManagementHandoff() {
            contentManagementHandoff = true
            sidebarFocusUnmask?.cancel()
            sidebarFocusMasked = true
            contentManagementHandoffTimeout?.cancel()
            contentManagementHandoffTimeout = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                endContentManagementHandoff()
            }
        }

        private func endContentManagementHandoff() {
            contentManagementHandoffTimeout?.cancel()
            contentManagementHandoffTimeout = nil
            contentManagementHandoff = false
            // Unmask once the rows' own focus has caught up: one focus
            // animation's length (TVSettingsSidebarButtonStyle) is plenty.
            sidebarFocusUnmask?.cancel()
            sidebarFocusUnmask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                sidebarFocusMasked = false
            }
        }

        private var tvDetail: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    switch selectedCategory {
                    case .premium:
                        tvPremiumDetail
                    case .profiles:
                        TVProfilesSettingsView()
                    case .playlists:
                        if let selectedPlaylist {
                            PlaylistDetailView(playlist: selectedPlaylist) {
                                self.selectedPlaylist = nil
                            }
                        } else {
                            tvPlaylistsDetail
                        }
                    case .epg:
                        EPGSettingsView()
                    case .library:
                        tvLibraryDetail
                    case .home:
                        tvHomeLayoutDetail
                    case .sports:
                        TVSportsSettingsPane()
                    case .player:
                        if showingOpenSubtitles {
                            TVOpenSubtitlesIntegrationView()
                        } else if let selectedEngineOptions {
                            tvEngineOptionsDetail(for: selectedEngineOptions)
                        } else if showingEngines {
                            tvEnginesDetail
                        } else if let preferredLanguagePane {
                            tvPreferredLanguageDetail(preferredLanguagePane)
                        } else {
                            tvPlayerDetail
                        }
                    case .iCloud:
                        TVCloudSyncSection()
                    case .connectedServices:
                        tvIntegrationsDetail
                    case .storage:
                        StorageManagementView()
                    case .help:
                        tvHelpDetail
                    case .about:
                        tvAboutDetail
                    case .appearance, .downloads, .developer:
                        EmptyView() // not offered on tvOS
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
            VStack(alignment: .leading, spacing: 36) {
                if trakt.isConfigured {
                    TVTraktIntegrationView()
                }
                if simkl.isConfigured {
                    TVSimklIntegrationView()
                }
            }
        }
    }

#endif
