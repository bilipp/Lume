//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels — categories sidebar; channels
//  for the selected category are loaded lazily via @Query.
//

import SwiftUI
import SwiftData

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
                    HStack(spacing: 0) {
                        // Category sidebar
                        CategorySidebar(
                            categories: sortedCategories,
                            selectedCategory: $selectedCategory
                        )
                        .frame(width: 200)

                        Divider()

                        // Channels list (lazy-loaded by category)
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
            }
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    PlaylistSwitcher(playlists: playlists, selectedPlaylistID: $selectedPlaylistID)
                }

                ToolbarItem(placement: .automatic) {
                    SortMenu(
                        categorySortRaw: $categorySortRaw,
                        contentSortRaw: $contentSortRaw
                    )
                }

                ToolbarItem(placement: .automatic) {
                    HStack {
                        Button {
                            showingSync = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }

                        Button {
                            // Search action
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
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
            .sheet(isPresented: $showingSync) {
                if let playlist = activePlaylist {
                    SyncProgressView(playlist: playlist, isPresented: $showingSync)
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            #endif
        }
    }

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
        .listStyle(.sidebar)
    }
}

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

#Preview {
    LiveTVView()
        .modelContainer(for: Playlist.self, inMemory: true)
}
