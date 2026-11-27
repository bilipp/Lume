//
//  MainTabView.swift
//  Lume
//
//  Main tab-based navigation for the app
//

import SwiftData
import SwiftUI

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    // Optional so previews (which don't inject it) don't crash.
    @Environment(PlaylistSwitchModel.self) private var playlistSwitch: PlaylistSwitchModel?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query private var playlists: [Playlist]
    /// Categories marked restricted, and categories hidden in Content
    /// Management. Fetched once here so a single source feeds the restriction
    /// context every content surface reads from the environment.
    @Query(filter: #Predicate<Category> { $0.isRestricted }) private var restrictedCategories: [Category]
    @Query(filter: #Predicate<Category> { $0.isHidden }) private var hiddenCategories: [Category]

    @AppStorage(SyncFrequency.storageKey) private var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    /// Whether the Sports tab appears in the tab bar (Settings toggle). When off,
    /// the hub is still reachable from the Home rail header.
    @AppStorage(SportsSyncService.tabEnabledKey) private var sportsTabEnabled = SportsSyncService.tabEnabledDefault
    @AppStorage(TabLayoutSettings.orderKey) private var tabOrderRaw = ""
    @AppStorage(TabLayoutSettings.homeEnabledKey) private var homeTabEnabled = TabLayoutSettings.homeEnabledDefault

    /// Selected tab and the Movies/Series navigation stacks, shared so an
    /// `onOpenURL` deep link can switch tabs and push a detail screen.
    /// Seeded from the stored tab layout so a hidden Home never mounts.
    @State private var router = DeepLinkRouter(selectedTab: TabLayoutSettings.storedLandingTab())

    /// The stream a `lume://resume` or `lume://play/...` (widget, Top Shelf)
    /// deep link asked to open. Presented directly here — the link can arrive
    /// on any tab — independent of any tab's own player cover.
    @State private var linkedMedia: PlayableMedia?

    /// Whether a `lume://downloads` deep link (a download Live Activity tap)
    /// asked for the downloads list. Presented as a sheet from here rather than
    /// pushed into Settings, so the link doesn't disturb whatever the user had
    /// open.
    @State private var showsDownloads = false
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @State private var autoSyncQueue = AutoSyncQueue()
    @State private var premium = PremiumManager.shared

    /// Memo behind `contentRestriction` — see `ContentRestrictionMemo`.
    @State private var restrictionMemo = ContentRestrictionMemo()

    #if !os(tvOS)
        /// The tabs held in the bar while a blocking sheet is up. Settings is a
        /// sheet raised from inside a tab, so rebuilding the bar under it (Home
        /// turned off, a reorder) would dismiss it.
        @State private var frozenTabs: [MainTab]?
    #endif

    private var syncFrequency: SyncFrequency {
        SyncFrequency.resolve(syncFrequencyRaw)
    }

    /// The playlists the content tabs are showing, resolved rather than read
    /// raw: the stored id can name a deleted playlist, or Combined can fall back
    /// to its priority-1 member, and auto-sync has to follow every surface there.
    private var catalogScope: CatalogScope {
        playlists.scope(for: selectedPlaylistID, isPremium: premium.isPremium)
    }

    /// The content tabs in the tab bar: an isolated playlist's own choice
    /// (Settings › Library › Tabs), or in Combined every type a member
    /// contributes.
    private func visibleTabs(in scope: CatalogScope) -> Set<PlaylistTab> {
        scope.visibleTabs(isolatedHidden: playlists.primaryMember(of: scope)?.hiddenTabs ?? [])
    }

    /// The tabs in the bar, in the viewer's order (Settings › Library › Tabs).
    private func orderedTabs(content: Set<PlaylistTab>) -> [MainTab] {
        TabLayoutSettings.visible(
            order: TabLayoutSettings.resolve(orderRaw: tabOrderRaw),
            content: content,
            homeEnabled: homeTabEnabled,
            sportsEnabled: sportsTabEnabled
        )
    }

    private var currentTabs: [MainTab] {
        orderedTabs(content: visibleTabs(in: catalogScope))
    }

    private func showsTab(_ tab: AppTab) -> Bool {
        guard let mainTab = MainTab(appTab: tab) else { return true }
        return currentTabs.contains(mainTab)
    }

    /// The tabs in the bar. Outside tvOS they hold still while a blocking
    /// sheet is up; see `frozenTabs`.
    private func displayedTabs(content: Set<PlaylistTab>) -> [MainTab] {
        let tabs = orderedTabs(content: content)
        #if os(tvOS)
            return tabs
        #else
            return frozenTabs ?? tabs
        #endif
    }

    private var landingTab: AppTab {
        TabLayoutSettings.landingTab(visible: currentTabs)
    }

    /// Whether the browse UI is covered: downloads, the add-device sheet (not a link
    /// still waiting for it), or a playlist / profile switch. Players, paywalls and Settings (a toolbar sheet this root can't see) report themselves.
    private var hasBlockingPresentation: Bool {
        hasOwnPresentation || router.presentedCloudPairing != nil
    }

    /// All of the above but the add-device sheet, which waits for these to clear.
    private var hasOwnPresentation: Bool {
        showsDownloads
            || playlistSwitch?.isSwitching == true
            || profileManager?.isSwitching == true
    }

    /// Whether a plain overlay sits over the tabs. Only tvOS layers those.
    private var overlayOwnsScreen: Bool {
        #if os(tvOS)
            blockingOverlayOwnsScreen || router.isQuickSwitchPresented
        #else
            false
        #endif
    }

    /// Hides categories (and their content) from every browse, Home and Search
    /// surface: the ones hidden in Content Management always, the restricted
    /// ones while a child profile is active.
    ///
    /// Routed through a memo: this root's body re-evaluates whenever any catalog
    /// write moves one of its `@Query`s, and constructing a `ContentRestriction`
    /// digests every excluded id — 433 of them on a real hidden-category set.
    /// The two id sets are cheap to rebuild and compare; the digest is not.
    private var contentRestriction: ContentRestriction {
        restrictionMemo.restriction(
            isActive: profileManager?.activeProfileIsChild ?? false,
            restricted: Set(restrictedCategories.map(\.id)),
            hidden: Set(hiddenCategories.map(\.id))
        )
    }

    var body: some View {
        @Bindable var router = router
        let scope = catalogScope
        let tabs = displayedTabs(content: visibleTabs(in: scope))
        return tabView(selection: $router.selectedTab, tabs: tabs)
        #if os(macOS)
            // Innermost, so the player it shows inherits everything below.
            .macInlinePlayerHost()
        #endif
        #if os(tvOS)
        .disabled(blockingOverlayOwnsScreen || router.isQuickSwitchPresented)
        // Attached OUTSIDE `.disabled` so the same button closes the modal it
        // opened, and above the tabs but below every player: the engines are
        // presented as `fullScreenCover`s from inside a tab, so their own
        // `onPlayPauseCommand` sits above this one in the focused chain and is
        // never shadowed. The guard covers the plain overlays instead, which
        // tvOS focus reaches straight through.
        .onPlayPauseCommand {
            guard playPauseTogglesQuickSwitch else { return }
            router.isQuickSwitchPresented.toggle()
        }
        #endif
        .environment(router)
        .environment(autoSyncQueue)
        .environment(\.contentRestriction, contentRestriction)
        .catalogScope(scope, playlists: playlists)
        // A tab switch is the one browse interaction that has no scroll
        // view of its own to stamp from, and it is the moment a merge is
        // most expensive — the incoming tab is re-running its queries.
        .onChange(of: router.selectedTab) {
            ContentIndexingService.shared.noteUserInteraction()
        }
        // Hiding the tab on screen, or switching to a playlist (or a
        // Combined set) without it, would leave the selection pointing at
        // nothing.
        .onChange(of: TabLayoutSettings.encode(tabs), initial: true) {
            fallBackIfSelectedTabIsHidden()
        }
        #if os(iOS)
        .tabBarMinimizeOnScrollDownIfAvailable()
        .castMiniController { linkedMedia = $0 }
        #endif
        .onOpenURL { url in
            handleDeepLink(url)
        }
        #if !os(macOS)
        .fullScreenCover(item: $linkedMedia) { media in
            FullScreenPlayerView(media: media)
        }
        #endif
        .task(id: playlists.count) {
            // A deleted playlist takes its running or queued sync with it.
            autoSyncQueue.dropSyncs(notIn: Set(playlists.map(\.id)))
            // On launch (and whenever a playlist is added) sync the active
            // playlist if it is due, plus any playlist that has never synced.
            enqueueDueSyncs(playlists)
        }
        .onChange(of: scope.token) {
            // On playlist switch, sync the newly selected one — or every due
            // Combined member — unless the switch asked to land in the
            // cached catalog instead. This is also where a playlist deferred
            // at launch for not being on screen gets its turn. Keyed on the
            // resolved scope rather than the stored selection, so a member
            // joining Combined, or Pro unlocking it, counts as a switch too.
            let deferred = playlistSwitch?.consumeDeferredDueSync() == true
            enqueueDueSyncs(deferred ? [] : playlists.members(of: catalogScope))
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the foreground re-checks staleness — for a long-lived
            // app this is the practical equivalent of "on launch".
            if phase == .active {
                enqueueDueSyncs(playlists)
            }
            // Coming back to `.active` also refreshes stale sports data.
            SportsSyncService.shared.isForeground = phase == .active
        }
        .onChange(of: autoSyncQueue.isBusy, initial: true) { _, busy in
            EPGSyncService.shared.setAutoSyncQueued(busy)
        }
        .onDisappear {
            // The queue goes with this view (deleting the last playlist
            // swaps the root back to onboarding); don't leave the guide
            // waiting on it.
            EPGSyncService.shared.setAutoSyncQueued(false)
        }
        .downloadsSheet(isPresented: $showsDownloads)
        .lumeCloudPairingSheet(router: router, rootIsCovered: hasOwnPresentation)
        .whatsNewSheet(rootIsCovered: hasBlockingPresentation || overlayOwnsScreen)
        .switchProgressOverlay(playlist: playlistSwitch, profile: profileManager)
        // The one fire point for the rating sheet. Here rather than at the
        // eleven player presentation sites: this view is the browse root,
        // so reaching it *is* the "player gone, nothing over it" condition.
        .appStoreReviewPrompt(isBlocked: hasBlockingPresentation)
        .reportsBrowseRootCovered(hasBlockingPresentation)
        #if os(tvOS)
            .overlay { tvOverlays }
        #endif
    }

    #if os(tvOS)
        /// The plain overlays layered over the tabs. One always-mounted container,
        /// so the fade is a transaction over this layer instead of over every
        /// animatable attribute in every live tab.
        private var tvOverlays: some View {
            ZStack {
                if let launch = router.multiViewLaunch {
                    MultiViewScreen(
                        seed: launch.seed,
                        onClose: { router.multiViewLaunch = nil }
                    )
                    // A launch's own id, so a grid started from a channel is a
                    // new view rather than the previous one re-rendered — which
                    // would keep the earlier session and drop the seed.
                    .id(launch.id)
                    .transition(.opacity)
                }

                if router.isQuickSwitchPresented {
                    // Built only while presented: a permanently mounted list of
                    // focusable rows would regrow the focus/AX responder walk
                    // that `activeOnly(_:selection:)` exists to contain.
                    TVQuickSwitchOverlay(
                        router: router,
                        playlists: playlists,
                        scope: catalogScope,
                        autoSyncQueue: autoSyncQueue
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: router.isQuickSwitchPresented)
        }

        private func tabView(selection: Binding<AppTab>, tabs: [MainTab]) -> some View {
            TabView(selection: selection) {
                Tab(value: AppTab.search) {
                    activeOnly(.search, selection: selection.wrappedValue) { SearchView() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }

                ForEach(tabs) { tab in
                    mainTab(tab, selection: selection.wrappedValue)
                }

                Tab(value: AppTab.settings) {
                    activeOnly(.settings, selection: selection.wrappedValue) { SettingsView() }
                } label: {
                    Image(systemName: "gear")
                }

                syncTab(selection: selection.wrappedValue)
            }
        }

        @TabContentBuilder<AppTab>
        private func syncTab(selection: AppTab) -> some TabContent<AppTab> {
            if showsSyncTab(selection: selection) {
                Tab(value: AppTab.sync) {
                    activeOnly(.sync, selection: selection) {
                        SyncActivityView(onClose: { router.selectedTab = landingTab })
                    }
                } label: {
                    Image(systemName: autoSyncQueue.recentFailure() == nil
                        ? "arrow.triangle.2.circlepath"
                        : "exclamationmark.arrow.triangle.2.circlepath")
                        .accessibilityLabel(Text("Sync"))
                }
            }
        }

        /// tvOS has no library toolbar to carry the sync indicator, so a sync
        /// that is running, waiting or has just failed gets a tab of its own
        /// at the end of the bar: the system lays it out, in any language, and
        /// the remote reaches it like every other tab. It stays while it is
        /// selected, so a sync finishing under the viewer doesn't pull the
        /// screen away.
        private func showsSyncTab(selection: AppTab) -> Bool {
            selection == .sync || autoSyncQueue.isBusy || autoSyncQueue.recentFailure() != nil
        }

        /// Whether something layered over the tabs owns the screen: tvOS focus is
        /// not clipped by z-order, so the tab bar and the cards behind a plain
        /// overlay would still take presses. The playlist switch is deliberately
        /// absent — it settles in under half a second, and disabling the tabs for
        /// it would move focus and hand it back somewhere else.
        private var blockingOverlayOwnsScreen: Bool {
            router.isMultiViewPresented
                || profileManager?.isSwitching == true
        }

        /// Whether Play/Pause may toggle the quick-switch modal right now. Off
        /// while a blocking overlay owns the screen, and off when neither column
        /// would have a focusable row — an empty modal over a disabled tab bar has
        /// nothing to hand focus to, and so nothing to deliver Menu either.
        private var playPauseTogglesQuickSwitch: Bool {
            if router.isQuickSwitchPresented {
                return true
            }
            guard !blockingOverlayOwnsScreen else { return false }
            return !playlists.isEmpty || profileManager?.isReady == true
        }

        /// tvOS `TabView` keeps every *visited* tab's view hierarchy alive, and
        /// each remote press triggers a focus/accessibility responder walk over
        /// the whole window — a device trace showed those walks dominating the
        /// EPG guide's scroll time once Home (hero + card rails) had been
        /// visited. Rendering only the selected tab keeps the walked hierarchy
        /// small; tab-local view state resets on switch, which is the usual
        /// tvOS behaviour anyway (navigation paths live in `DeepLinkRouter`
        /// and survive).
        @ViewBuilder
        func activeOnly(_ tab: AppTab, selection: AppTab, @ViewBuilder content: () -> some View) -> some View {
            if selection == tab {
                content()
            } else {
                Color.clear
            }
        }
    #else
        /// Search stays mounted: it holds only the query the viewer typed and a
        /// playlist lookup. The content tabs unmount after sitting unshown — see
        /// `IdleUnmountingTab`.
        private func tabView(selection: Binding<AppTab>, tabs: [MainTab]) -> some View {
            TabView(selection: selection) {
                ForEach(tabs) { tab in
                    mainTab(tab, selection: selection.wrappedValue)
                }

                // macOS 15's tab bar drops a `role: .search` tab entirely — even
                // with an explicit label (the previous workaround), the search tab
                // never renders, leaving no way to reach Search there. macOS 26
                // renders the role correctly, as do iOS/visionOS 18+, so only
                // macOS 15 falls back to a plain tab and every other system keeps
                // the dedicated search treatment.
                if #unavailable(macOS 26) {
                    Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                        SearchView()
                    }
                } else {
                    Tab(value: AppTab.search, role: .search) {
                        SearchView().castMiniControllerInset()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
            }
            .onChange(of: ScreenOccupancy.shared.blockingSheetIsVisible) { _, isVisible in
                if isVisible {
                    frozenTabs = tabs
                } else {
                    frozenTabs = nil
                    fallBackIfSelectedTabIsHidden()
                }
            }
        }
    #endif

    /// Deferred: on tvOS the selection can change inside the focus engine's
    /// animated context.
    private func fallBackIfSelectedTabIsHidden() {
        Task { @MainActor in
            let tabs = currentTabs
            if let selected = MainTab(appTab: router.selectedTab), !tabs.contains(selected) {
                router.selectedTab = TabLayoutSettings.landingTab(visible: tabs)
            }
        }
    }

    // MARK: - Deep links

    /// Resolves a `lume://movie/{tmdbId}` / `lume://series/{tmdbId}` link to a
    /// catalog item, switches to the matching tab and pushes its detail screen.
    /// `play`/`open` links (from widgets and the Top Shelf) launch playback or
    /// a detail screen by catalog id. Silently ignores unknown links and titles
    /// not present in the catalog (e.g. a tmdbId that was never synced or
    /// enriched).
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case let .movie(tmdbId):
            guard let movie = resolveMovie(tmdbId: tmdbId) else { return }
            openMovieDetail(movie)
        case let .series(tmdbId):
            guard let series = resolveSeries(tmdbId: tmdbId) else { return }
            openSeriesDetail(series)
        case .playMovie, .playEpisode, .playLive, .openSeries, .openMovie:
            handleWidgetLink(link)
        case .resume:
            // When a player session is already up, foregrounding the app is
            // all that's needed; otherwise reopen the last played stream where
            // it left off.
            guard NowPlayingService.shared.currentMedia == nil,
                  let media = PlaybackResumeStore.load() else { return }
            #if os(macOS)
                MacPlayerWindowRouter.shared.play(media, using: openWindow)
            #else
                linkedMedia = media
            #endif
        case .downloads:
            // The download Live Activity was tapped.
            showsDownloads = true
        case let .cloudPair(code):
            // Ignored on tvOS: no camera to scan a pairing QR with.
            #if !os(tvOS)
                showsDownloads = false
                router.requestCloudPairing(code: code)
            #endif
        }
    }

    /// Handles a widget / Top Shelf link: `play` launches playback, `open`
    /// pushes a movie or series detail screen — both by catalog id.
    private func handleWidgetLink(_ link: DeepLink) {
        switch WidgetLinkResolver.resolve(link, in: modelContext, restriction: contentRestriction) {
        case let .play(media):
            // Mirrors the in-app play paths: external player hand-off first,
            // then a player window (macOS) or a full-screen cover.
            if ExternalPlayback.open(media) { return }
            #if os(macOS)
                MacPlayerWindowRouter.shared.play(media, using: openWindow)
            #else
                linkedMedia = media
            #endif
        case let .openSeries(series):
            openSeriesDetail(series)
        case let .openMovie(movie):
            openMovieDetail(movie)
        case nil:
            break
        }
    }

    /// Pushes a movie detail screen on the Movies tab — a no-op when the
    /// profile hides that tab.
    private func openMovieDetail(_ movie: Movie) {
        guard showsTab(.movies) else { return }
        router.selectedTab = .movies
        router.moviesPath = NavigationPath()
        router.moviesPath.append(movie)
    }

    /// Pushes a series detail screen on the Series tab — a no-op when the
    /// profile hides that tab.
    private func openSeriesDetail(_ series: Series) {
        guard showsTab(.series) else { return }
        router.selectedTab = .series
        router.seriesPath = NavigationPath()
        router.seriesPath.append(series)
    }

    /// Finds a movie by `tmdbId`, preferring a copy from the playlists on
    /// screen but falling back to any other playlist's copy the plan unlocks.
    /// Restricted categories stay hidden for a child profile.
    private func resolveMovie(tmdbId: Int) -> Movie? {
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let restriction = contentRestriction
        let matcher = CatalogScope.Matcher(catalogScope)
        let matches = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !restriction.hides(categoryID: $0.categoryId) && !playlists.isLocked(contentID: $0.id) }
        return matches.first { matcher.contains($0.id, .movies) } ?? matches.first
    }

    private func resolveSeries(tmdbId: Int) -> Series? {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let restriction = contentRestriction
        let matcher = CatalogScope.Matcher(catalogScope)
        let matches = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !restriction.hides(categoryID: $0.categoryId) && !playlists.isLocked(contentID: $0.id) }
        return matches.first { matcher.contains($0.id, .series) } ?? matches.first
    }

    // MARK: - Automatic sync

    /// A playlist the free plan locks never syncs.
    private func enqueueDueSyncs(_ candidates: [Playlist]) {
        autoSyncQueue.enqueueDue(
            candidates.filter { !playlists.isLocked($0) },
            scope: catalogScope,
            frequency: syncFrequency,
            context: modelContext
        )
    }
}

// MARK: - Downloads sheet presentation

private extension View {
    /// Presents the downloads list as a sheet, in the same navigation + dismiss
    /// chrome Settings gives it. The download Live Activity's tap target, so it
    /// is reachable without disturbing whatever tab the user had open.
    @ViewBuilder
    func downloadsSheet(isPresented: Binding<Bool>) -> some View {
        #if os(tvOS)
            // tvOS has no downloads feature to show.
            self
        #else
            sheet(isPresented: isPresented) {
                NavigationStack {
                    DownloadsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresented.wrappedValue = false }
                            }
                        }
                }
                #if os(macOS)
                // A `List` in a frameless macOS sheet collapses to zero
                // height, leaving the sheet rendering as a bare toolbar.
                .frame(minWidth: 480, minHeight: 440)
                #endif
            }
        #endif
    }
}

#Preview("No Playlists") {
    MainTabView()
}

#Preview("With Playlists") {
    MainTabView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                container.mainContext.insert(playlist)
            }
        }
}
