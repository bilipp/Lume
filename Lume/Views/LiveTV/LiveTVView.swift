//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels — categories sidebar; channels
//  for the selected category are loaded lazily via @Query.
//

import SwiftData
import SwiftUI

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

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
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
            #if os(iOS)
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

                if let category = selectedCategory {
                    ChannelsList(category: category, sort: contentSort) { stream in
                        playChannel(stream)
                    }
                    .id("\(category.id)-\(contentSort.rawValue)")
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

            if let category = selectedCategory {
                ChannelsList(category: category, sort: contentSort) { stream in
                    playChannel(stream)
                }
                .id("\(category.id)-\(contentSort.rawValue)")
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

                if let category = selectedCategory {
                    TVChannelsList(category: category, sort: contentSort) { stream in
                        playChannel(stream)
                    }
                    .id("\(category.id)-\(contentSort.rawValue)")
                    .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        "Select a Category",
                        systemImage: "list.bullet",
                        description: Text("Choose a category from the list")
                    )
                    .frame(maxWidth: .infinity)
                }
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

// MARK: - tvOS Category Sidebar

#if os(tvOS)
    struct TVCategorySidebar: View {
        let categories: [Category]
        @Binding var selectedCategory: Category?

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(categories) { category in
                        TVCategoryRow(
                            category: category,
                            isSelected: selectedCategory?.id == category.id
                        ) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 40)
            }
            .focusSection()
        }
    }

    private struct TVCategoryRow: View {
        let category: Category
        let isSelected: Bool
        let action: () -> Void

        @FocusState private var isFocused: Bool

        var body: some View {
            Button(action: action) {
                Text(category.name)
                    .font(.system(size: 30, weight: isSelected || isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused || isSelected ? .white : .white.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(background)
                    )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($isFocused)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        private var background: AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white.opacity(0.22)) }
            if isSelected { return AnyShapeStyle(.white.opacity(0.1)) }
            return AnyShapeStyle(.clear)
        }
    }

    // MARK: - tvOS Channels List

    struct TVChannelsList: View {
        let category: Category
        let onPlay: (LiveStream) -> Void
        @Query private var streams: [LiveStream]

        init(category: Category, sort: ContentSortOption, onPlay: @escaping (LiveStream) -> Void) {
            self.category = category
            self.onPlay = onPlay
            let categoryId = category.id
            _streams = Query(
                filter: #Predicate<LiveStream> { $0.categoryId == categoryId },
                sort: sort.liveStreamDescriptors
            )
        }

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if streams.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(streams) { stream in
                            TVChannelRow(stream: stream) {
                                onPlay(stream)
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .focusSection()
        }
    }

    private struct TVChannelRow: View {
        let stream: LiveStream
        let onPlay: () -> Void

        @Query private var epgListings: [EPGListing]
        @FocusState private var isFocused: Bool

        init(stream: LiveStream, onPlay: @escaping () -> Void) {
            self.stream = stream
            self.onPlay = onPlay
            let channelId = stream.epgChannelId ?? ""
            let now = Date()
            _epgListings = Query(
                filter: #Predicate<EPGListing> { $0.channelId == channelId && $0.end > now },
                sort: [SortDescriptor(\.start)]
            )
        }

        private var now: Date {
            Date()
        }

        private var currentEPG: EPGListing? {
            epgListings.first { $0.start <= now && now < $0.end }
        }

        private var nextEPG: EPGListing? {
            epgListings.filter { $0.start > now }.min { $0.start < $1.start }
        }

        var body: some View {
            Button(action: onPlay) {
                HStack(spacing: 24) {
                    logo

                    VStack(alignment: .leading, spacing: 6) {
                        Text(stream.name)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)

                        if let current = currentEPG {
                            Text(current.title)
                                .font(.system(size: 25))
                                .foregroundStyle(secondaryColor)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(current.start, style: .time)
                                Text("–")
                                Text(current.end, style: .time)
                            }
                            .font(.system(size: 22))
                            .foregroundStyle(tertiaryColor)

                            if let next = nextEPG {
                                HStack(spacing: 6) {
                                    Text("Next:")
                                    Text(next.title).lineLimit(1)
                                    Text(next.start, style: .time)
                                }
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                            }
                        } else if stream.epgChannelId != nil {
                            Text("No EPG data")
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                        } else {
                            Text("Live")
                                .font(.system(size: 22))
                                .foregroundStyle(secondaryColor)
                        }

                        if stream.tvArchive > 0 {
                            Label("Catchup: \(stream.tvArchiveDuration)d", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.blue)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tertiaryColor)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.white.opacity(0.06)))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($isFocused)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        private var logo: some View {
            AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.white.opacity(0.12)).overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle().fill(Color.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(secondaryColor)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var primaryColor: Color {
            .white
        }

        private var secondaryColor: Color {
            .white.opacity(0.7)
        }

        private var tertiaryColor: Color {
            .white.opacity(0.45)
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
            filter: #Predicate<LiveStream> { $0.categoryId == categoryId },
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
