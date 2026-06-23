//
//  SeriesView.swift
//  Lume
//
//  Main view for browsing TV series. Each category shows a preview row;
//  "Show All" navigates to the full category view.
//

import SwiftData
import SwiftUI

struct SeriesView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    // Optional so previews (which don't inject it) fall back to a local path.
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    @State private var fallbackPath = NavigationPath()
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "series" && $0.isHidden == false })
    private var categories: [Category]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var showingSync = false
    @State private var showingSettings = false
    @State private var genres: [String] = []

    @AppStorage(SortStorageKey.seriesCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private let previewLimit = 20

    /// How many categories render as full inline preview rows. Each preview row
    /// carries its own live `@Query`, so capping them keeps the browse screen
    /// fast; the remaining categories surface as lightweight name tiles below.
    private let previewCategoryLimit = 4

    var body: some View {
        // Resolve once per render — `sortedCategories` filters + sorts every
        // playlist's categories, so reading it three times (the emptiness check
        // plus the preview/remaining splits) tripled that work.
        let sorted = sortedCategories
        NavigationStack(path: navigationPath) {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "tv",
                        description: Text("Add a playlist in Settings to start browsing series")
                    )
                } else if sorted.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Series",
                            systemImage: "tv.fill",
                            description: Text("Sync your playlist to load TV series")
                        )
                    }
                } else {
                    let remaining = Array(sorted.dropFirst(previewCategoryLimit))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                            SeriesCollectionRow(kind: .recentlyWatched, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
                            SeriesCollectionRow(kind: .favorites, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
                            SeriesCollectionRow(kind: .recentlyAdded, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)

                            ForEach(sorted.prefix(previewCategoryLimit)) { category in
                                SeriesCategoryPreview(category: category, limit: previewLimit, sort: contentSort, animationNamespace: animationNamespace)
                                    .id("\(category.id)-\(contentSort.rawValue)")
                            }

                            if !genres.isEmpty {
                                GenreGridSection(genres: genres, type: .series)
                            }

                            if !remaining.isEmpty {
                                CategoryGridSection(title: "All Categories", categories: remaining)
                                    .padding(.top, 12)
                            }
                        }
                        .padding(.vertical)
                    }
                    .task(id: playlistPrefix) {
                        genres = GenreDerivation.seriesGenres(in: modelContext, playlistPrefix: playlistPrefix, restriction: restriction)
                    }
                }
            }
            .platformNavigationTitle("Series")
            .profileMenuToolbar()
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                categorySortRaw: $categorySortRaw,
                contentSortRaw: $contentSortRaw,
                showingSync: $showingSync,
                showingSettings: $showingSettings,
                activePlaylist: activePlaylist
            ))
            .navigationDestination(for: Category.self) { category in
                SeriesCategoryView(category: category, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: LibraryCollection.self) { collection in
                SeriesCollectionView(kind: collection.kind, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: GenreSelection.self) { selection in
                SeriesGenreView(genre: selection.genre, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
                #endif
            }
        }
    }

    /// Drives the stack from the shared `DeepLinkRouter` so an `onOpenURL` push
    /// lands here; falls back to a local path in previews where no router exists.
    private var navigationPath: Binding<NavigationPath> {
        guard let router else { return $fallbackPath }
        return Binding(get: { router.seriesPath }, set: { router.seriesPath = $0 })
    }

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Series/Category of the active playlist shares. Used to
    /// scope the cross-category collection rows in-memory.
    private var playlistPrefix: String {
        activePlaylist.map { "\($0.id.uuidString)-" } ?? ""
    }

    /// Categories scoped to the active playlist. The `@Query` fetches every
    /// playlist's categories (SwiftData can't parameterize a `@Query` on view
    /// state), so we isolate by the playlist-prefixed category `id` here.
    private var sortedCategories: [Category] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return categorySort.sort(categories.filter { $0.id.hasPrefix(prefix) && !restriction.hides(categoryID: $0.id) })
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
