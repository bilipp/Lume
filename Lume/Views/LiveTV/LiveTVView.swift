//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels — categories sidebar; channels
//  for the selected category are loaded lazily via @Query.
//

import SwiftData
import SwiftUI

/// How the Live TV detail area presents channels: a scannable list or the EPG
/// timeline grid. Persisted per device across launches.
nonisolated enum LiveTVLayoutMode: String, CaseIterable, Identifiable {
    case list
    case guide

    var id: String {
        rawValue
    }

    var displayName: String {
        self == .list ? String(localized: "List") : String(localized: "Guide")
    }

    var systemImage: String {
        self == .list ? "list.bullet" : "tablecells"
    }

    static let storageKey = "lume.liveTV.layoutMode"

    static func platformDefault(isTV: Bool) -> LiveTVLayoutMode {
        isTV ? .guide : .list
    }

    #if os(tvOS)
        static let defaultMode = platformDefault(isTV: true)
    #else
        static let defaultMode = platformDefault(isTV: false)
    #endif

    /// Resolves the stored raw value; a missing or unknown one reads as the
    /// platform default, so a user who never picked follows it.
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultMode
    }
}

struct LiveTVView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "live" && $0.isHidden == false })
    private var categories: [Category]

    /// Keeps the rail's categories from being filtered and sorted on every body
    /// pass — see `LiveTVCategoryMemo`. Whether the two virtual sections appear
    /// is `LiveTVSections`' job; it owns the bounded probes that answer it.
    @State private var categoryMemo = LiveTVCategoryMemo()

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    /// Holds the selection so it survives the tab being unmounted; the
    /// fallbacks serve previews, which have no router.
    @Environment(DeepLinkRouter.self) private var tabRouter: DeepLinkRouter?
    @State private var fallbackSection: LiveTVSection?
    @State private var fallbackSeededPrefix: String?
    @State private var showingSync = false
    @State private var playingMedia: PlayableMedia?
    @State private var showingSettings = false
    #if os(tvOS)
        @Environment(DeepLinkRouter.self) private var router
        @State private var guidePreview = GuidePreviewController()
        @State private var guideHero = GuideHeroModel()
    #else
        /// Non-nil while Multi-View is up; carries the channels it opened with,
        /// when it was started from a channel rather than the toolbar.
        @State private var multiViewLaunch: MultiViewLaunch?
    #endif
    @State private var showingPaywall = false
    @State private var premium = PremiumManager.shared

    @AppStorage(SortStorageKey.liveCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.liveContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LiveTVLayoutMode.storageKey) private var layoutModeRaw: String = LiveTVLayoutMode.defaultMode.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private var layoutMode: LiveTVLayoutMode {
        LiveTVLayoutMode(storedValue: layoutModeRaw)
    }

    /// The channel detail area for the selected section, honouring the current
    /// layout mode. Shared by every platform's layout.
    private func detail(for section: LiveTVSection) -> some View {
        Group {
            if layoutMode == .guide {
                EPGGuideView(
                    scope: section.scope,
                    playlistPrefix: playlistPrefix,
                    sort: contentSort,
                    onPlay: { playChannel($0, scope: section.scope) },
                    onPlayCatchup: { playCatchup($0, cell: $1) },
                    onStartMultiView: { startMultiView(with: $0) }
                )
            } else {
                channelList(for: section)
            }
        }
        .id("\(section.id)-\(contentSort.rawValue)-\(layoutModeRaw)")
    }

    @ViewBuilder
    private func channelList(for section: LiveTVSection) -> some View {
        #if os(tvOS)
            TVChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                sort: contentSort,
                sourceType: activePlaylist?.knownSourceType,
                onStartMultiView: { startMultiView(with: $0) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
            .frame(maxWidth: .infinity)
        #else
            ChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                sort: contentSort,
                onStartMultiView: { startMultiView(with: $0) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add a playlist in Settings to start watching live TV")
                    )
                } else if categories.isEmpty || sourceHasNoLiveChannels {
                    VStack(spacing: 20) {
                        LiveTVEmptyState(sourceType: activePlaylist?.knownSourceType)
                    }
                } else {
                    // The rail resolves in a child view: gating the two virtual
                    // sections is a pair of playlist-scoped `LIMIT 1` probes, and
                    // a `@Query` carries that scope only when its descriptor is
                    // built in an `init` the active playlist reaches.
                    LiveTVSections(
                        playlistPrefix: playlistPrefix,
                        restriction: restriction,
                        categorySections: categorySections
                    ) { sections in
                        layout(for: sections)
                            .task(id: playlistPrefix) { seedSelection(from: sections) }
                    }
                }
            }
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                categorySortRaw: $categorySortRaw,
                contentSortRaw: $contentSortRaw,
                showingSync: $showingSync,
                showingSettings: $showingSettings,
                activePlaylist: activePlaylist
            ))
            // After `libraryToolbar`, so Recordings and Multi-View lead the bar
            // as their own cluster, never beside Settings. Guide or List is
            // chosen in Settings › Live TV on every platform. The switcher's
            // title (shown by `libraryToolbar` with several playlists) tells
            // the cluster how much room is left for it.
            .liveTVToolbarCluster(
                multiViewAvailable: !playlists.isEmpty && !categories.isEmpty,
                switcherTitle: playlists.count > 1 ? activePlaylist?.name : nil
            ) {
                openMultiView()
            }
            #if os(iOS) || os(tvOS)
            .fullScreenCover(item: $playingMedia) { media in
                #if os(tvOS)
                    FullScreenPlayerView(media: media, adopting: guidePreview.handle)
                #else
                    FullScreenPlayerView(media: media)
                #endif
            }
            #endif
            #if os(iOS)
            .fullScreenCover(item: $multiViewLaunch) { launch in
                MultiViewScreen(seed: launch.seed)
            }
            #endif
            .paywall(isPresented: $showingPaywall, highlight: .multiView)
            .recordActionFlow(observesWhileVisible: false)
        }
    }

    // MARK: - Platform-specific layouts

    /// This platform's browse layout for the resolved rail. The displayed
    /// section resolves here, once per render — rail and detail pane both need it.
    @ViewBuilder
    private func layout(for sections: [LiveTVSection]) -> some View {
        let displayed = displayedSection(in: sections)
        #if os(iOS)
            iOSLayout(sections: sections, displayed: displayed)
        #elseif os(tvOS)
            tvOSLayout(sections: sections, displayed: displayed)
        #else
            macOSLayout(sections: sections, displayed: displayed)
        #endif
    }

    #if os(iOS)
        private func iOSLayout(sections: [LiveTVSection], displayed: LiveTVSection?) -> some View {
            VStack(spacing: 0) {
                CategoryBar(
                    sections: sections,
                    selectedSection: selectedSectionBinding
                )

                if let displayed {
                    detail(for: displayed)
                } else {
                    ContentUnavailableView(
                        "Select a Category",
                        systemImage: "list.bullet",
                        description: Text("Choose a category from the list")
                    )
                }
            }
        }
    #endif

    private func macOSLayout(sections: [LiveTVSection], displayed: LiveTVSection?) -> some View {
        HStack(spacing: 0) {
            CategorySidebar(
                sections: sections,
                selectedSection: selectedSectionBinding
            )
            .frame(width: 200)

            Divider()

            if let displayed {
                detail(for: displayed)
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "list.bullet",
                    description: Text("Choose a category from the sidebar")
                )
            }
        }
    }

    #if os(tvOS)
        /// One shape for both modes: the category sidebar on the leading edge
        /// beside the content area, which shows either the channel list or the
        /// programme guide (picked in Settings › Player › Live TV).
        private func tvOSLayout(sections: [LiveTVSection], displayed: LiveTVSection?) -> some View {
            TVLiveTVScreen(
                sections: sections,
                selectedSection: selectedSectionBinding,
                displayedSection: displayed,
                contentSort: contentSort,
                onPlay: { playChannel($0, scope: displayed?.scope) },
                onPlayCatchup: { playCatchup($0, cell: $1) },
                onStartMultiView: { startMultiView(with: $0) },
                playlistPrefix: playlistPrefix,
                sourceType: activePlaylist?.knownSourceType,
                layoutMode: layoutMode,
                preview: EPGGuidePreviewInputs(
                    media: { [activePlaylist] stream in
                        activePlaylist.flatMap { PlayableMedia.from(stream: stream, playlist: $0) }
                    },
                    playlistID: activePlaylist?.id,
                    controller: guidePreview,
                    hero: guideHero
                )
            )
            // Never from an `onDisappear`, which a `fullScreenCover` doesn't
            // deliver.
            .guidePreviewSuspension(guidePreview, playingMedia: $playingMedia)
            // The list has no settled channel to tint the glow from.
            .background {
                TVLiveTVBackground(hero: layoutMode == .guide ? guideHero : nil)
                    .ignoresSafeArea()
            }
        }
    #endif

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// A WebDAV share carries no live channels, so its rail stays empty even
    /// when another playlist has live categories — the unscoped `categories`
    /// query cannot see that on its own. Same for the media servers, whose
    /// Live TV tuner APIs are not synced.
    private var sourceHasNoLiveChannels: Bool {
        activePlaylist?.knownSourceType.map { !$0.canCarryLiveChannels } == true && categorySections.isEmpty
    }

    /// The id prefix every Category / LiveStream of the active playlist shares.
    private var playlistPrefix: String {
        activePlaylist.map { "\($0.id.uuidString)-" } ?? ""
    }

    /// The rail's category entries: the active playlist's live categories this
    /// viewer may see, in the chosen order. The `@Query` fetches every playlist's
    /// categories (SwiftData can't parameterize a `@Query` on view state), so the
    /// isolation by playlist-prefixed `id` — and the sort — happen here, memoized
    /// so a body pass that changed nothing about them costs a key comparison.
    private var categorySections: [LiveTVSection] {
        categoryMemo.sections(
            categories: categories,
            playlistPrefix: playlistPrefix,
            sort: categorySort,
            restriction: restriction
        )
    }

    private var selectedSection: LiveTVSection? {
        get { tabRouter.map(\.liveTVSection) ?? fallbackSection }
        nonmutating set {
            if let tabRouter { tabRouter.liveTVSection = newValue } else { fallbackSection = newValue }
        }
    }

    private var selectedSectionBinding: Binding<LiveTVSection?> {
        Binding(get: { selectedSection }, set: { selectedSection = $0 })
    }

    /// The playlist `selectedSection` was last seeded for — see `seedSelection`.
    private var seededPrefix: String? {
        get { tabRouter.map(\.liveTVSeededPrefix) ?? fallbackSeededPrefix }
        nonmutating set {
            if let tabRouter { tabRouter.liveTVSeededPrefix = newValue } else { fallbackSeededPrefix = newValue }
        }
    }

    /// Points the rail at its first section. On first appearance that only means
    /// seeding an empty selection; on a playlist switch it resets unconditionally,
    /// because the previous selection belonged to the playlist that just went
    /// away — the two moments the removed `.task` / `.onChange(of:)` pair covered.
    /// Anything narrower (a category hidden in Content Management, the last
    /// favorite removed) is left to `displayedSection(in:)`, as before.
    private func seedSelection(from sections: [LiveTVSection]) {
        if seededPrefix != nil, seededPrefix != playlistPrefix {
            selectedSection = sections.first
        } else if selectedSection == nil {
            selectedSection = sections.first
        }
        seededPrefix = playlistPrefix
    }

    /// The section to render in the detail pane. Normally the user's selection,
    /// but if that section just disappeared (a category hidden in Content
    /// Management, or the last favorite removed) fall back to the first available
    /// one rather than keep showing stale content.
    private func displayedSection(in sections: [LiveTVSection]) -> LiveTVSection? {
        guard let selectedSection else { return sections.first }
        return sections.contains { $0.id == selectedSection.id }
            ? selectedSection
            : sections.first
    }

    /// `scope` is the section the channel was picked from; it travels with the
    /// media so in-player channel surfing stays inside that list.
    private func playChannel(_ stream: LiveStream, scope: LiveChannelScope?) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist, scope: scope) else { return }
        present(media)
    }

    /// Replays a past programme from the channel's catch-up archive.
    private func playCatchup(_ stream: LiveStream, cell: EPGProgramCell) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.catchup(
                  stream: stream,
                  playlist: playlist,
                  programTitle: cell.title,
                  start: cell.start,
                  end: cell.end
              ) else { return }
        present(media)
    }

    /// Opens Multi-View on a channel picked from the list, so the grid starts
    /// with something playing rather than two empty tiles.
    private func startMultiView(with stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist)
        else {
            return
        }
        openMultiView(seed: [media])
    }

    /// Opens Multi-View, or the paywall when the viewer isn't on Lume Pro.
    private func openMultiView(seed: [PlayableMedia] = []) {
        guard premium.isPremium else {
            showingPaywall = true
            return
        }
        #if os(macOS)
            // The window is a singleton, so it cannot be built around a launch:
            // hand the channels over and let the grid adopt them on appear.
            MultiViewLaunchQueue.shared.pending = seed
            openWindow(id: "multiview")
        #elseif os(tvOS)
            // Presented by `MainTabView`, above the tab bar — see the router.
            router.multiViewLaunch = MultiViewLaunch(seed: seed)
        #else
            multiViewLaunch = MultiViewLaunch(seed: seed)
        #endif
    }

    private func present(_ media: PlayableMedia) {
        if ExternalPlayback.open(media) {
            #if os(tvOS)
                guidePreview.stopForExternalPlayback()
            #endif
            return
        }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #elseif os(tvOS)
            guidePreview.prepareToPresent(media)
            playingMedia = media
        #else
            playingMedia = media
        #endif
    }
}

#Preview("Empty") {
    LiveTVView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    LiveTVView()
        .modelContainer(previewContainer())
}

#Preview("No Playlists") {
    LiveTVView()
}
