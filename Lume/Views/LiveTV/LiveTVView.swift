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

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var selectedCategory: Category?
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

    /// The channel detail area for the selected category, honouring the current
    /// layout mode. Shared by every platform's layout.
    private func detail(for category: Category) -> some View {
        Group {
            if layoutMode == .guide {
                EPGGuideView(category: category, sort: contentSort) { stream in
                    playChannel(stream)
                }
            } else {
                channelList(for: category)
            }
        }
        .id("\(category.id)-\(contentSort.rawValue)-\(layoutModeRaw)")
    }

    @ViewBuilder
    private func channelList(for category: Category) -> some View {
        #if os(tvOS)
            TVChannelsList(category: category, sort: contentSort) { stream in
                playChannel(stream)
            }
            .frame(maxWidth: .infinity)
        #else
            ChannelsList(category: category, sort: contentSort) { stream in
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
                    if selectedCategory == nil, let first = sortedCategories.first {
                        selectedCategory = first
                    }
                }
                .onChange(of: selectedPlaylistID) {
                    // Switching playlists invalidates the current category selection,
                    // which belongs to the previous playlist. Reset to the new
                    // playlist's first category so the channel list stays in sync.
                    selectedCategory = sortedCategories.first
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
                    categories: sortedCategories,
                    selectedCategory: $selectedCategory
                )

                if let category = displayedCategory {
                    detail(for: category)
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
                categories: sortedCategories,
                selectedCategory: $selectedCategory
            )
            .frame(width: 200)

            Divider()

            if let category = displayedCategory {
                detail(for: category)
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
        /// Two focus sections tuned for the 10-foot UI: a wide, readable category
        /// rail on the left and a large channel list on the right. The macOS
        /// layout's fixed 200pt sidebar is far too narrow for a TV — it wraps
        /// category names one word per line — so tvOS gets its own components.
        private var tvOSLayout: some View {
            HStack(spacing: 0) {
                TVCategorySidebar(
                    categories: sortedCategories,
                    selectedCategory: $selectedCategory
                )
                .frame(width: 560)

                VStack(spacing: 0) {
                    HStack {
                        layoutModePicker
                            .frame(maxWidth: 360)
                        Spacer()
                    }
                    .padding(.horizontal, 60)
                    .padding(.top, 40)
                    .focusSection()

                    if let category = displayedCategory {
                        detail(for: category)
                    } else {
                        ContentUnavailableView(
                            "Select a Category",
                            systemImage: "list.bullet",
                            description: Text("Choose a category from the list")
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    #endif

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// Categories scoped to the active playlist. The `@Query` fetches every
    /// playlist's categories (SwiftData can't parameterize a `@Query` on view
    /// state), so we isolate by the playlist-prefixed category `id` here.
    private var sortedCategories: [Category] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return categorySort.sort(categories.filter { $0.id.hasPrefix(prefix) })
    }

    /// The category to render in the detail pane. Normally the user's selection,
    /// but if that category was just hidden in Content Management it's no longer
    /// in `sortedCategories`, so fall back to the first visible one rather than
    /// keep showing a now-hidden category's channels.
    private var displayedCategory: Category? {
        guard let selectedCategory else { return sortedCategories.first }
        return sortedCategories.contains { $0.id == selectedCategory.id }
            ? selectedCategory
            : sortedCategories.first
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
    let categories: [Category]
    @Binding var selectedCategory: Category?

    var body: some View {
        List(categories) { category in
            Button {
                selectedCategory = category
            } label: {
                HStack {
                    Text(category.name)
                        .font(.headline)
                        .foregroundStyle(selectedCategory?.id == category.id ? Color.accentColor : Color.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                selectedCategory?.id == category.id
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
        let categories: [Category]
        @Binding var selectedCategory: Category?

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.name)
                                .font(.subheadline)
                                .fontWeight(selectedCategory?.id == category.id ? .semibold : .regular)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    selectedCategory?.id == category.id
                                        ? Color.accentColor
                                        : Color.gray.opacity(0.15)
                                )
                                .foregroundStyle(
                                    selectedCategory?.id == category.id
                                        ? .white
                                        : .primary
                                )
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
    let category: Category
    let onPlay: (LiveStream) -> Void
    @Query private var streams: [LiveStream]

    init(category: Category, sort: ContentSortOption, onPlay: @escaping (LiveStream) -> Void) {
        self.category = category
        self.onPlay = onPlay
        let categoryId = category.id
        _streams = Query(
            filter: #Predicate<LiveStream> { $0.categoryId == categoryId && $0.isHidden == false },
            sort: sort.liveStreamDescriptors
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if streams.isEmpty {
                    ContentUnavailableView(
                        "No Channels",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("This category has no channels")
                    )
                } else {
                    ForEach(streams) { stream in
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
