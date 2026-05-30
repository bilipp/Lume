//
//  MoviesView.swift
//  Lume
//
//  Main view for browsing movies. Each category shows a preview row;
//  "Show All" navigates to the full category view.
//

import SwiftUI
import SwiftData

struct MoviesView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "vod" && $0.isHidden == false })
    private var categories: [Category]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var showingSync = false
    @State private var showingSettings = false

    @AppStorage(SortStorageKey.movieCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    /// How many movies to render inline per category. The full list is reachable
    /// via the per-row "Show All" link.
    private let previewLimit = 20

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "film.stack",
                        description: Text("Add a playlist in Settings to start browsing movies")
                    )
                } else if sortedCategories.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Movies",
                            systemImage: "film.stack",
                            description: Text("Sync your playlist to load movies")
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
                                MovieCategoryPreview(category: category, limit: previewLimit, sort: contentSort, animationNamespace: animationNamespace)
                                    .id("\(category.id)-\(contentSort.rawValue)")
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Movies")
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
                            Image(systemName: "gear")
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
                MovieCategoryView(category: category, sort: contentSort, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
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

/// One category row on the main view: shows up to `limit` movies inline.
/// Uses a fetch-limited `@Query` parameterized on `categoryId` so each row pulls
/// only its own slice — never the full category contents.
struct MovieCategoryPreview: View {
    let category: Category
    @Query private var movies: [Movie]
    var animationNamespace: Namespace.ID?

    init(category: Category, limit: Int, sort: ContentSortOption, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.animationNamespace = animationNamespace
        let categoryId = category.id
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate<Movie> { $0.categoryId == categoryId },
            sortBy: sort.movieDescriptors
        )
        descriptor.fetchLimit = limit
        _movies = Query(descriptor)
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

            if movies.isEmpty {
                Text("No movies in this category")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(movies) { movie in
                            NavigationLink(value: movie) {
                                MovieCardView(movie: movie)
                                    .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
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

struct MovieCategoryView: View {
    let category: Category
    @Query private var movies: [Movie]
    var animationNamespace: Namespace.ID?

    init(category: Category, sort: ContentSortOption, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.animationNamespace = animationNamespace
        let categoryId = category.id
        _movies = Query(
            filter: #Predicate<Movie> { $0.categoryId == categoryId },
            sort: sort.movieDescriptors
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            if movies.isEmpty {
                ContentUnavailableView(
                    "No Movies",
                    systemImage: "film.stack",
                    description: Text("This category has no movies")
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(movies) { movie in
                        NavigationLink(value: movie) {
                            MovieCardView(movie: movie)
                                .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
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
    MoviesView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    MoviesView()
        .modelContainer(previewContainer())
}
