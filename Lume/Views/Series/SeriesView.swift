//
//  SeriesView.swift
//  Lume
//
//  Main view for browsing TV series. Each category shows a preview row;
//  "Show All" navigates to the full category view.
//

import SwiftUI
import SwiftData

struct SeriesView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "series" && $0.isHidden == false })
    private var categories: [Category]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var showingSync = false
    @State private var showingSettings = false

    @AppStorage(SortStorageKey.seriesCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private let previewLimit = 20

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "tv",
                        description: Text("Add a playlist in Settings to start browsing series")
                    )
                } else if sortedCategories.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Series",
                            systemImage: "tv.fill",
                            description: Text("Sync your playlist to load TV series")
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                            ForEach(sortedCategories) { category in
                                SeriesCategoryPreview(category: category, limit: previewLimit, sort: contentSort, animationNamespace: animationNamespace)
                                    .id("\(category.id)-\(contentSort.rawValue)")
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Series")
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
                            showingSettings = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingSync) {
                if let playlist = activePlaylist {
                    SyncProgressView(playlist: playlist, isPresented: $showingSync)
                }
            }
            .navigationDestination(for: Category.self) { category in
                SeriesCategoryView(category: category, sort: contentSort, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: animationNamespace)
                    .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
            }
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
}

// MARK: - Category Preview Row

struct SeriesCategoryPreview: View {
    let category: Category
    @Query private var series: [Series]
    var animationNamespace: Namespace.ID?

    init(category: Category, limit: Int, sort: ContentSortOption, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.animationNamespace = animationNamespace
        let categoryId = category.id
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate<Series> { $0.categoryId == categoryId },
            sortBy: sort.seriesDescriptors
        )
        descriptor.fetchLimit = limit
        _series = Query(descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.name)
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                NavigationLink(value: category) {
                    Text("Show All")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            if series.isEmpty {
                Text("No series in this category")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(series) { item in
                            NavigationLink(value: item) {
                                SeriesCardView(series: item)
                                    .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 220)
            }
        }
    }
}

// MARK: - Full Category View (Show All)

struct SeriesCategoryView: View {
    let category: Category
    @Query private var series: [Series]
    var animationNamespace: Namespace.ID?

    init(category: Category, sort: ContentSortOption, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.animationNamespace = animationNamespace
        let categoryId = category.id
        _series = Query(
            filter: #Predicate<Series> { $0.categoryId == categoryId },
            sort: sort.seriesDescriptors
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            if series.isEmpty {
                ContentUnavailableView(
                    "No Series",
                    systemImage: "tv.fill",
                    description: Text("This category has no series")
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(series) { item in
                        NavigationLink(value: item) {
                            SeriesCardView(series: item)
                                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(category.name)
    }
}

#Preview("Empty") {
    SeriesView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    SeriesView()
        .modelContainer(previewContainer())
}
