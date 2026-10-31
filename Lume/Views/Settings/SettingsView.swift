import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Not `private`: read by the SettingsView+Library extension (separate file).
    @Environment(CloudSyncCoordinator.self) var cloudSync: CloudSyncCoordinator?
    /// Not `private`: read by the SettingsView+Playlists / +Library extensions (separate files).
    @Query var playlists: [Playlist]
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
    /// Badges the Sync row while Lume Cloud's recovery key is unseen.
    @AppStorage(LumeCloudSettings.Key.recoveryKeyViewed) private var lumeCloudRecoveryKeyViewed = false
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
        /// The category whose content is shown in the right pane. Changes only
        /// when a rail row is activated (Live TV's model): moving focus through
        /// the rail just highlights.
        @State private var selectedCategory: SettingsCategory = .profiles
        /// Bumped to hand focus to the rail's selected category — Menu from a
        /// pane's top level, or the tab-bar entry catcher.
        @State private var railFocusRequest = 0
        /// Bumped as activating a category sends focus into its pane, so the
        /// rail keeps it should the pane have nothing to focus (About).
        @State private var paneFocusRequest = 0
        /// Whether focus is settled in the rail, for the tab-bar entry catcher.
        @State private var railFocused = false
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
        /// Where focus belongs while Content Management swaps the whole pane
        /// in or out — the drill-in, the PIN pad giving way to it, or Menu
        /// closing it. See `beginPaneHandoff`.
        @State private var paneHandoff: TVSettingsPaneHandoff?
        @State private var paneHandoffTimeout: Task<Void, Never>?
        /// Whether focus is anywhere in the detail pane. Together with
        /// `railFocused` it tells whether focus is outside Settings — up in
        /// the tab bar — which is when `tvTabBarEntryCatcher` takes it.
        @FocusState private var detailFocused: Bool
        /// The rows that open a sub-page, so Menu can put focus back on the
        /// one it leaves. Not `private`: the panes' extensions tag their rows.
        @FocusState var drillInFocus: TVSettingsDrillIn?
        /// Whether the Player category is drilled into Engines — the priority
        /// list and the per-engine option rows — in place. Not `private`: read
        /// by the SettingsView+TVPlayer extension (separate file).
        @State var showingEngines = false
        /// Whether the Player category is drilled into OpenSubtitles in place.
        /// Not `private`: set by the SettingsView+TVPlayer extension (separate file).
        @State var showingOpenSubtitles = false
        /// Whether the Player category is drilled into Subtitle Style in place.
        /// Not `private`: set by the SettingsView+TVPlayer extension (separate file).
        @State var showingSubtitleStyle = false
        /// Whether the Live TV category is drilled into the Recording Server
        /// pane, in place (same reasoning as `selectedPlaylist`).
        @State private var showingRecordingServer = false
        /// How far the Recording Server pane is drilled in, in place. `nil` is
        /// its top level.
        @State private var recordingServerRoute: TVRecordingServerRoute?
        /// The Sync pane's Lume Cloud drill-in, in place; `nil` is its top level.
        @State private var syncRoute: TVLumeCloudRoute?
        /// Bumped by a pane to scroll the detail back to its top.
        @State private var tvDetailScrollToTopRequest = 0
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
        @AppStorage(HomeLayoutSettings.enabledSectionsKey) var homeEnabledSectionsRaw = ""
        @AppStorage(HomeLayoutSettings.recentlyWatchedIncludesLiveTVKey)
        var homeRecentlyWatchedIncludesLiveTV = HomeLayoutSettings.recentlyWatchedIncludesLiveTVDefault

        /// The user's ordered engine fallback list (migrates the legacy single-engine
        /// key on first read). The first entry is the primary engine. Not `private`:
        /// read by the SettingsView+TVPlayer extension (separate file).
        var enginePriority: [PlayerEngineKind] {
            PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
        }
    #endif

    /// Whether this build has credentials for any Connected Services entry.
    private var hasConnectedServices: Bool {
        TraktService.shared.isConfigured || SimklService.shared.isConfigured || MDBListService.shared.isConfigured
    }

    private func showsBadge(for category: SettingsCategory) -> Bool {
        category == .iCloud && LumeCloudSettings.showsRecoveryKeyBadge(backend: cloudSync?.status.backend, viewed: lumeCloudRecoveryKeyViewed)
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
                    #if os(iOS)
                        SiriTipSection()
                    #endif
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
                        Image(systemName: "chevron.forward")
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
                    SettingsCategoryRowLabel(category: category, value: value(for: category), showsBadge: showsBadge(for: category))
                }
            }
        }

        /// The trailing value: only for single-choice pages, plus the Lume Pro
        /// and Sync status.
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

// MARK: - tvOS (Apple TV Settings-style two-pane layout)

#if os(tvOS)

    extension SettingsView {
        private var tvBody: some View {
            NavigationStack {
                HStack(alignment: .top, spacing: TVSidebarRail.paneSpacing) {
                    TVSidebarRail(
                        items: railItems,
                        selectedID: selectedCategory.id,
                        focusRequest: railFocusRequest,
                        focusHandOffRequest: paneFocusRequest,
                        masksFocus: paneHandoff != nil,
                        onFocusChange: railFocusDidChange
                    )
                    tvDetailContainer
                        .focused($detailFocused)
                        .onExitCommand(perform: handleDetailMenu)
                }
                .overlay(alignment: .top) { tvTabBarEntryCatcher }
                .background {
                    TVAmbientBackground(hero: nil)
                        .ignoresSafeArea()
                }
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .fullScreenCover(isPresented: $showingAddPlaylist) {
                    LoginView(isModal: true)
                }
            }
        }

        /// The categories in the iOS root list's order, ungrouped and without icons.
        private var railItems: [TVSidebarRailItem] {
            SettingsCategory.visible(hasConnectedServices: hasConnectedServices).map { category in
                let badge = showsBadge(for: category)
                return TVSidebarRailItem(id: category.id, title: Text(category.title), icon: badge ? "exclamationmark.circle" : nil, iconAccessibilityLabel: badge ? Text("Recovery key not viewed") : nil) {
                    activate(category)
                }
            }
        }

        /// Opens `category` at its top level — also the open one, which backs
        /// out of any sub-page — and moves focus into its pane.
        private func activate(_ category: SettingsCategory) {
            selectedCategory = category
            closeDrillIns()
            paneFocusRequest += 1
            // Deferred: the pane only holds the new category's rows a render
            // later.
            Task { @MainActor in detailFocused = true }
        }

        private func closeDrillIns() {
            selectedPlaylist = nil
            showingContentManagement = false
            showingEngines = false
            showingOpenSubtitles = false
            showingSubtitleStyle = false
            showingRecordingServer = false
            recordingServerRoute = nil
            syncRoute = nil
            selectedEngineOptions = nil
            preferredLanguagePane = nil
        }

        /// Menu in the pane backs out of the innermost sub-page onto the row
        /// that opened it, and from a pane's top level returns to the rail.
        private func handleDetailMenu() {
            guard let opener = closeInnermostDrillIn() else {
                railFocusRequest += 1
                return
            }
            // Deferred: the row only exists again a render later, and a
            // same-frame write from a Menu callback is dropped anyway.
            Task { @MainActor in drillInFocus = opener }
        }

        /// Closes the sub-page on top and returns the row that opened it; nil
        /// at the pane's top level. Checked in the order `tvDetail` draws
        /// them, so the visible one closes.
        private func closeInnermostDrillIn() -> TVSettingsDrillIn? {
            switch selectedCategory {
            case .playlists:
                guard let playlist = selectedPlaylist else { return nil }
                selectedPlaylist = nil
                return .playlist(playlist.id)
            case .library:
                guard showingContentManagement else { return nil }
                beginPaneHandoff(.drillIn(.contentManagement))
                showingContentManagement = false
                return .contentManagement
            case .liveTV:
                // The pairing step backs out to the pane's top level itself.
                guard showingRecordingServer else { return nil }
                showingRecordingServer = false
                recordingServerRoute = nil
                return .recordingServer
            case .player:
                return closeInnermostPlayerDrillIn()
            case .iCloud:
                guard let route = syncRoute else { return nil }
                syncRoute = nil
                return route.opener
            default:
                return nil
            }
        }

        private func railFocusDidChange(_ isFocused: Bool) {
            railFocused = isFocused
            guard let paneHandoff else { return }
            if isFocused {
                // Deferred: a same-frame write from a focus callback is dropped.
                Task { @MainActor in
                    switch paneHandoff {
                    case .contentManagement: contentManagementFocused = true
                    case let .drillIn(row): drillInFocus = row
                    }
                }
            } else {
                endPaneHandoff()
            }
        }

        /// Replacing the pane wholesale removes the focused view with the
        /// scroll view around it — the Categories & Channels row, the PIN pad
        /// once it unlocks, or Content Management itself on Menu — and the
        /// engine then drops focus on the rail's selected row. The handoff
        /// passes that focus on to `target` and, until focus has left the rail
        /// again, draws the rail unfocused so Library never flashes. A timeout
        /// closes it should focus never pass through the rail, so it can't
        /// swallow the user's own later move there.
        private func beginPaneHandoff(_ target: TVSettingsPaneHandoff) {
            paneHandoff = target
            paneHandoffTimeout?.cancel()
            paneHandoffTimeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                endPaneHandoff()
            }
        }

        /// Not `private`: the Library pane's row calls it
        /// (SettingsView+Library).
        func beginContentManagementHandoff() {
            beginPaneHandoff(.contentManagement)
        }

        private func endPaneHandoff() {
            paneHandoffTimeout?.cancel()
            paneHandoffTimeout = nil
            paneHandoff = nil
        }

        /// Pressing down from the tab bar lands on whatever sits under the
        /// Settings tab — the detail pane's top row, never the rail, which is
        /// far off to the left. This invisible full-width strip across the top
        /// is nearer than any of them, so it catches that move and hands it to
        /// the rail's selected category. It's focusable only while focus is
        /// outside Settings, so moving up from the panes still reaches the tab
        /// bar.
        private var tvTabBarEntryCatcher: some View {
            TVTabBarEntryCatcher(isEnabled: !railFocused && !detailFocused) {
                railFocusRequest += 1
            }
            .accessibilityHidden(true)
            // Raised into the gap between the tab bar and the screen's top,
            // as Live TV's is: the tab bar ends at y ≈ 114 and the screen
            // starts at 158 (tvOS 26.5), so the band sits at y ≈ 130.
            .alignmentGuide(.top) { $0[.top] + 28 }
        }

        /// Content Management brings its own scroll view, so it replaces the
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

        private var tvDetail: some View {
            ScrollViewReader { proxy in
                tvDetailScrollView
                    .onChange(of: tvDetailScrollToTopRequest) {
                        withAnimation { proxy.scrollTo(Self.tvDetailTopID, anchor: .top) }
                    }
            }
        }

        private static let tvDetailTopID = "settings.detail.top"

        private var tvDetailScrollView: some View {
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
                    case .liveTV:
                        if showingRecordingServer {
                            TVRecordingServerSettingsView(route: $recordingServerRoute)
                        } else {
                            TVLiveTVSettingsPane(
                                showingRecordingServer: $showingRecordingServer,
                                drillInFocus: $drillInFocus
                            ) { presentPaywall($0) }
                        }
                    case .sports:
                        TVSportsSettingsPane()
                    case .player:
                        if showingOpenSubtitles {
                            TVOpenSubtitlesIntegrationView()
                        } else if showingSubtitleStyle {
                            TVSubtitleStyleSettingsView()
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
                        TVSyncSettingsPane(route: $syncRoute, drillInFocus: $drillInFocus) { tvDetailScrollToTopRequest += 1 }
                    case .connectedServices:
                        TVConnectedServicesView()
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
                // Lume Pro lays its benefits out in two columns across the
                // whole pane.
                .tvSettingsPaneContent(maxWidth: selectedCategory == .premium ? .infinity : TVSettingsMetrics.detailMaxWidth)
                .id(Self.tvDetailTopID)
            }
            // A fresh scroll position per category; sub-pages keep theirs.
            .id(selectedCategory)
            .focusSection()
        }
    }

    /// Where focus goes once Content Management has swapped the whole pane in
    /// or out.
    enum TVSettingsPaneHandoff {
        case contentManagement
        case drillIn(TVSettingsDrillIn)
    }

    /// A row that opens a sub-page in the Settings pane, focused again when
    /// Menu backs out of it.
    enum TVSettingsDrillIn: Hashable {
        case playlist(UUID)
        case contentManagement
        case recordingServer
        case audioLanguages, addLanguage
        case subtitleStyle, openSubtitles
        case engines
        case engineOptions(PlayerEngineKind)
        case syncBackend(SyncBackendSelection)
        case lumeCloudDeviceName, lumeCloudAddDevice, lumeCloudDevices, lumeCloudRecoveryKey
    }

#endif
