//
//  GenreBrowse.swift
//  Lume
//
//  "Browse by Genre" on the Movies and Series tabs. Genre cuts across the
//  provider categories — a title's genre comes from TMDB/playlist metadata, not
//  the category it lives in — so these surfaces are driven by the title's
//  `genre` string rather than a `categoryId`, mirroring the cross-category
//  library collection rows.
//

import SwiftData
import SwiftUI

// MARK: - Genre derivation

/// Upper bound on the fetch that enumerates a playlist's genres. The genre
/// vocabulary is tiny (a couple dozen names) and saturates almost immediately,
/// so a bounded sample surfaces every genre in practice while keeping the
/// derivation cheap on libraries with tens of thousands of titles — the same
/// trade-off `LibraryCollectionRows` makes for "Recently Added".
private let genreSampleLimit = 5000

enum GenreDerivation {
    static func movieGenres(in context: ModelContext, playlistPrefix: String, restriction: ContentRestriction) -> [String] {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.genre != nil })
        descriptor.fetchLimit = genreSampleLimit
        let movies = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.id.hasPrefix(playlistPrefix) }
            .excludingRestricted(restriction)
        return GenreParser.distinctByFrequency(movies.map(\.genre))
    }

    static func seriesGenres(in context: ModelContext, playlistPrefix: String, restriction: ContentRestriction) -> [String] {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.genre != nil })
        descriptor.fetchLimit = genreSampleLimit
        let series = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.id.hasPrefix(playlistPrefix) }
            .excludingRestricted(restriction)
        return GenreParser.distinctByFrequency(series.map(\.genre))
    }
}

// MARK: - Browse-by-genre section

/// A tile grid of the genres present in the active playlist, most-common first.
/// Each tile navigates to that genre's full grid.
///
/// The owning view derives the genres and renders this only when the list is
/// non-empty: a view that collapses to nothing never receives `.task`/`.onAppear`
/// (the same EmptyView lifecycle trap `CachedAsyncImage` hit), so the derivation
/// must live on an always-present host — the browse `ScrollView` — not here.
struct GenreGridSection: View {
    let genres: [String]
    let type: CategoryType

    private let columns = [GridItem(.adaptive(minimum: CategoryTileMetrics.minimum), spacing: CategoryTileMetrics.spacing)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse by Genre")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: CategoryTileMetrics.spacing) {
                ForEach(genres, id: \.self) { genre in
                    NavigationLink(value: GenreSelection(genre: genre, type: type)) {
                        CategoryTile(name: genre)
                    }
                    .posterCardButtonStyle()
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Genre detail grids

/// The full grid of movies in a genre, reachable from a genre tile. The fetch
/// narrows to candidate rows in SQLite with `localizedStandardContains`, then
/// re-filters to exact-token matches in memory so substrings can't sneak in.
struct MovieGenreView: View {
    let genre: String
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var movies: [Movie] = []

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    var body: some View {
        CategoryContentGrid(
            title: genre,
            items: movies,
            animationNamespace: animationNamespace,
            emptyTitle: "No Movies",
            emptyIcon: "film.stack",
            emptyDescription: "No movies in this genre",
            sortRaw: $contentSortRaw,
            card: { MovieCardView(movie: $0) }
        )
        .task(id: contentSortRaw) {
            let token = genre
            let descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { ($0.genre?.localizedStandardContains(token)) ?? false },
                sortBy: contentSort.movieDescriptors
            )
            movies = ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { $0.id.hasPrefix(playlistPrefix) && GenreParser.contains($0.genre, genre: token) }
                .excludingRestricted(restriction)
        }
    }
}

/// The full grid of series in a genre.
struct SeriesGenreView: View {
    let genre: String
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var series: [Series] = []

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    var body: some View {
        CategoryContentGrid(
            title: genre,
            items: series,
            animationNamespace: animationNamespace,
            emptyTitle: "No Series",
            emptyIcon: "tv.fill",
            emptyDescription: "No series in this genre",
            sortRaw: $contentSortRaw,
            card: { SeriesCardView(series: $0) }
        )
        .task(id: contentSortRaw) {
            let token = genre
            let descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { ($0.genre?.localizedStandardContains(token)) ?? false },
                sortBy: contentSort.seriesDescriptors
            )
            series = ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { $0.id.hasPrefix(playlistPrefix) && GenreParser.contains($0.genre, genre: token) }
                .excludingRestricted(restriction)
        }
    }
}
