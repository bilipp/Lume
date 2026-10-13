//
//  MoviesView.swift
//  Lume
//
//  Main view for browsing movies. Each category shows a preview row;
//  "Show All" navigates to the full category view.
//

import SwiftData
import SwiftUI

struct MoviesView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    /// The playlists the categories, collection rows and genres read from: one
    /// playlist, or the Combined members.
    @Environment(\.catalogScope) private var scope
    // Optional so previews (which don't inject it) fall back to a local path.
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    @State private var fallbackPath = NavigationPath()
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "vod" && $0.isHidden == false })
    private var categories: [Category]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var showingSync = false
    @State private var showingSettings = false
    @State private var genres: [String] = []

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

    /// How many categories render as full inline preview rows. Each preview row
    /// carries its own live `@Query`, so capping them keeps the browse screen
    /// fast; the remaining categories surface as lightweight name tiles below.
    private let previewCategoryLimit = 4

    var body: some View {
        // Resolve once per render — `categoryLayout` filters + sorts every
        // member's categories, so reading it per use multiplied that work.
        let layout = categoryLayout
        NavigationStack(path: navigationPath) {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "film.stack",
                        description: Text("Add a playlist in Settings to start browsing movies")
                    )
                } else if layout.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Movies",
                            systemImage: "film.stack",
                            description: Text("Sync your playlist to load movies")
                        )
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                            MovieCollectionRow(kind: .recentlyWatched, scope: scope, animationNamespace: animationNamespace)
                            MovieCollectionRow(kind: .favorites, scope: scope, animationNamespace: animationNamespace)
                            MovieCollectionRow(kind: .recentlyAdded, scope: scope, animationNamespace: animationNamespace)

                            ForEach(layout.previews) { category in
                                MovieCategoryPreview(category: category, limit: previewLimit, sort: contentSort, animationNamespace: animationNamespace)
                                    .id("\(category.id)-\(contentSort.rawValue)")
                            }

                            if !genres.isEmpty {
                                GenreGridSection(genres: genres, type: .vod)
                            }

                            ForEach(layout.remaining) { group in
                                CategoryGridSection(group: group)
                                    .padding(.top, 12)
                            }
                        }
                        .padding(.vertical)
                    }
                    .browseActivity()
                    .task(id: scope.token) {
                        genres = await GenreDerivation.movieGenres(in: modelContext.container, scope: scope, restriction: restriction)
                    }
                }
            }
            .platformNavigationTitle("Movies")
            .profileMenuToolbar()
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                categorySortRaw: $categorySortRaw,
                contentSortRaw: $contentSortRaw,
                showingSync: $showingSync,
                showingSettings: $showingSettings
            ))
            .navigationDestination(for: Category.self) { category in
                MovieCategoryView(category: category, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: LibraryCollection.self) { collection in
                MovieCollectionView(kind: collection.kind, scope: scope, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: GenreSelection.self) { selection in
                MovieGenreView(genre: selection.genre, scope: scope, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
                #endif
            }
        }
    }

    /// Drives the stack from the shared `DeepLinkRouter` so an `onOpenURL` push
    /// lands here; falls back to a local path in previews where no router exists.
    private var navigationPath: Binding<NavigationPath> {
        guard let router else { return $fallbackPath }
        return Binding(get: { router.moviesPath }, set: { router.moviesPath = $0 })
    }

    /// Categories in scope, as preview rows plus one tile group per member.
    /// The `@Query` fetches every playlist's categories (SwiftData can't
    /// parameterize a `@Query` on view state), so the isolation by
    /// playlist-prefixed category `id` happens here.
    private var categoryLayout: LibraryCategoryLayout {
        LibraryCategoryLayout.make(
            categories: categories,
            members: playlists.members(of: scope, for: .movies).map { (id: $0.id, name: $0.name) },
            sort: categorySort,
            restriction: restriction,
            previewLimit: previewCategoryLimit
        )
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
