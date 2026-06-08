//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels — categories sidebar; channels
//  for the selected category are loaded lazily via @Query.
//

import SwiftData
import SwiftUI

/// How the Live TV detail area presents channels: a scannable list (default) or
/// the EPG timeline grid. Persisted across launches.
enum LiveTVLayoutMode: String, CaseIterable, Identifiable {
    case list
    case guide

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        self == .list ? "List" : "Guide"
    }

    var systemImage: String {
        self == .list ? "list.bullet" : "tablecells"
    }

    static let storageKey = "lume.liveTV.layoutMode"
}

struct LiveTVView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "live" && $0.isHidden == false })
    private var categories: [Category]

    /// Drives whether the Favorites / Recently Watched virtual sections appear in
    /// the rail. Queried across all playlists, then scoped in-memory by prefix.
    @Query(filter: #Predicate<LiveStream> { $0.isFavorite && $0.isHidden == false })
    private var favoriteStreams: [LiveStream]
    @Query(filter: #Predicate<LiveStream> { $0.lastWatchedDate != nil && $0.isHidden == false })
    private var recentStreams: [LiveStream]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var selectedSection: LiveTVSection?
    @State private var showingSync = false
    @State private var playingMedia: PlayableMedia?
    @State private var showingSettings = false

    @AppStorage(SortStorageKey.liveCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.liveContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LiveTVLayoutMode.storageKey) private var layoutModeRaw: String = LiveTVLayoutMode.list.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private var layoutMode: LiveTVLayoutMode {
        LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    /// Guide/List segmented switch shared across platforms.
    private var layoutModePicker: some View {
        Picker("Layout", selection: $layoutModeRaw) {
            ForEach(LiveTVLayoutMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// The channel detail area for the selected section, honouring the current
    /// layout mode. Shared by every platform's layout.
    private func detail(for section: LiveTVSection) -> some View {
        Group {
            if layoutMode == .guide {
                EPGGuideView(scope: section.scope, playlistPrefix: playlistPrefix, sort: contentSort) { stream in
                    playChannel(stream)
                }
            } else {
                channelList(for: section)
            }
        }
        .id("\(section.id)-\(contentSort.rawValue)-\(layoutModeRaw)")
    }

    @ViewBuilder
    private func channelList(for section: LiveTVSection) -> some View {
        #if os(tvOS)
            TVChannelsList(scope: section.scope, playlistPrefix: playlistPrefix, sort: contentSort) { stream in
                playChannel(stream)
            }
            .frame(maxWidth: .infinity)
        #else
            ChannelsList(scope: section.scope, playlistPrefix: playlistPrefix, sort: contentSort) { stream in
                playChannel(stream)
            }
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
                } else if categories.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("Sync your playlist to load live TV channels")
                        )

                        if let playlist = activePlaylist {
                            Button {
                                selectedPlaylistID = playlist.id.uuidString
                                showingSync = true
                            } label: {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    #if os(iOS)
                        iOSLayout
                    #elseif os(tvOS)
                        tvOSLayout
                    #else
                        macOSLayout
                    #endif
                }
            }
            .platformNavigationTitle("Live TV")
            #if os(iOS) || os(macOS)
                .toolbar {
                    if !playlists.isEmpty, !categories.isEmpty {
                        ToolbarItem(placement: .principal) {
                            layoutModePicker
                                .frame(maxWidth: 240)
                        }
                    }
                }
            #endif
                .libraryToolbar(config: LibraryToolbarConfiguration(
                    playlists: playlists,
                    selectedPlaylistID: $selectedPlaylistID,
                    categorySortRaw: $categorySortRaw,
                    contentSortRaw: $contentSortRaw,
                    showingSync: $showingSync,
                    showingSettings: $showingSettings,
                    activePlaylist: activePlaylist
                ))
                .task {
                    if selectedSection == nil, let first = sortedSections.first {
                        selectedSection = first
                    }
                }
                .onChange(of: selectedPlaylistID) {
                    // Switching playlists invalidates the current selection, which
                    // belongs to the previous playlist. Reset to the new playlist's
                    // first section so the channel list stays in sync.
                    selectedSection = sortedSections.first
                }
            #if os(iOS) || os(tvOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
        }
    }

    // MARK: - Platform-specific layouts

    #if os(iOS)
        private var iOSLayout: some View {
            VStack(spacing: 0) {
                CategoryBar(
                    sections: sortedSections,
                    selectedSection: $selectedSection
                )

                if let section = displayedSection {
                    detail(for: section)
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

    private var macOSLayout: some View {
        HStack(spacing: 0) {
            CategorySidebar(
                sections: sortedSections,
                selectedSection: $selectedSection
            )
            .frame(width: 200)

            Divider()

            if let section = displayedSection {
                detail(for: section)
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
        /// One shape for both modes: a slim category rail on the leading edge —
        /// topped by a single List/Guide switch — beside the content area, which
        /// shows either the channel list or the programme guide. Sharing one rail
        /// and one switch keeps moving between the two views consistent.
        private var tvOSLayout: some View {
            TVLiveTVScreen(
                sections: sortedSections,
                selectedSection: $selectedSection,
                displayedSection: displayedSection,
                layoutModeRaw: $layoutModeRaw,
                contentSort: contentSort,
                onPlay: { playChannel($0) },
                playlistPrefix: playlistPrefix
            )
        }
    #endif

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Category / LiveStream of the active playlist shares.
    private var playlistPrefix: String {
        activePlaylist.map { "\($0.id.uuidString)-" } ?? ""
    }

    /// Categories scoped to the active playlist. The `@Query` fetches every
    /// playlist's categories (SwiftData can't parameterize a `@Query` on view
    /// state), so we isolate by the playlist-prefixed category `id` here.
    private var sortedCategories: [Category] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return categorySort.sort(categories.filter { $0.id.hasPrefix(prefix) })
    }

    /// Whether the active playlist has any favorited / recently-watched channels,
    /// gating the corresponding virtual sections so empty collections never show.
    private var hasFavorites: Bool {
        !playlistPrefix.isEmpty && favoriteStreams.contains { $0.id.hasPrefix(playlistPrefix) }
    }

    private var hasRecents: Bool {
        !playlistPrefix.isEmpty && recentStreams.contains { $0.id.hasPrefix(playlistPrefix) }
    }

    /// The rail's entries: the virtual collections (when non-empty) pinned above
    /// the synced categories.
    private var sortedSections: [LiveTVSection] {
        var sections: [LiveTVSection] = []
        if hasFavorites { sections.append(.favorites) }
        if hasRecents { sections.append(.recentlyWatched) }
        sections.append(contentsOf: sortedCategories.map(LiveTVSection.category))
        return sections
    }

    /// The section to render in the detail pane. Normally the user's selection,
    /// but if that section just disappeared (a category hidden in Content
    /// Management, or the last favorite removed) fall back to the first available
    /// one rather than keep showing stale content.
    private var displayedSection: LiveTVSection? {
        guard let selectedSection else { return sortedSections.first }
        return sortedSections.contains { $0.id == selectedSection.id }
            ? selectedSection
            : sortedSections.first
    }

    private func playChannel(_ stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }
}

// MARK: - Category Sidebar

struct CategorySidebar: View {
    let sections: [LiveTVSection]
    @Binding var selectedSection: LiveTVSection?

    var body: some View {
        List(sections) { section in
            let isSelected = selectedSection?.id == section.id
            Button {
                selectedSection = section
            } label: {
                HStack(spacing: 8) {
                    if let icon = section.icon {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    section.titleText
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
        }
        #if !os(tvOS)
        .listStyle(.sidebar)
        #endif
    }
}

// MARK: - iOS Category Bar

#if os(iOS)
    struct CategoryBar: View {
        let sections: [LiveTVSection]
        @Binding var selectedSection: LiveTVSection?

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sections) { section in
                        let isSelected = selectedSection?.id == section.id
                        Button {
                            selectedSection = section
                        } label: {
                            HStack(spacing: 5) {
                                if let icon = section.icon {
                                    Image(systemName: icon)
                                        .font(.caption)
                                }
                                section.titleText
                                    .font(.subheadline)
                            }
                            .fontWeight(isSelected ? .semibold : .regular)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                isSelected
                                    ? Color.accentColor
                                    : Color.gray.opacity(0.15)
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)

            Divider()
        }
    }
#endif

// MARK: - Channels List

struct ChannelsList: View {
    let scope: LiveChannelScope
    let playlistPrefix: String
    let onPlay: (LiveStream) -> Void
    @Query private var streams: [LiveStream]

    init(scope: LiveChannelScope, playlistPrefix: String, sort: ContentSortOption, onPlay: @escaping (LiveStream) -> Void) {
        self.scope = scope
        self.playlistPrefix = playlistPrefix
        self.onPlay = onPlay
        _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
    }

    private var scopedStreams: [LiveStream] {
        LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if scopedStreams.isEmpty {
                    ContentUnavailableView(
                        "No Channels",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("This category has no channels")
                    )
                } else {
                    ForEach(scopedStreams) { stream in
                        Button {
                            onPlay(stream)
                        } label: {
                            LiveStreamCardView(stream: stream)
                                .padding(.horizontal)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 88)
                    }
                }
            }
        }
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
