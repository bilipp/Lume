//
//  LibraryCollectionRows.swift
//  Lume
//
//  The "Recently Watched" and "Favorites" rows shown above the category rows on
//  the Movies and Series tabs, plus their "Show All" grids. These collections
//  cut across categories — a favorite or recently-watched title can live in any
//  category — so they're driven by their own predicates rather than a
//  `categoryId`, mirroring the Home screen's rows.
//
//  Each row scopes its @Query results to the active playlist in-memory (the same
//  approach the rest of the app uses, since SwiftData can't parameterise a
//  @Query on a playlist-prefixed id), then caps to a preview length. Rows render
//  nothing when empty so a fresh library degrades gracefully.
//

import SwiftData
import SwiftUI

// MARK: - Navigation value

/// A cross-category library collection reachable via "Show All". Carried as a
/// navigation value so Movies and Series can each register a destination for it.
struct LibraryCollection: Hashable {
    enum Kind: String, Hashable {
        case recentlyWatched
        case favorites

        var title: LocalizedStringKey {
            switch self {
            case .recentlyWatched: "Recently Watched"
            case .favorites: "Favorites"
            }
        }

        var emptyIcon: String {
            switch self {
            case .recentlyWatched: "clock.arrow.circlepath"
            case .favorites: "heart"
            }
        }
    }

    let kind: Kind
    let type: CategoryType
}

/// How many items each preview row shows before "Show All".
private let collectionPreviewLimit = 20

// MARK: - Shared preview row

/// A titled horizontal rail with a trailing "Show All" link into the full
/// collection grid. Mirrors `CategoryPreviewRow`, but its header is a plain
/// title plus a `LibraryCollection` destination rather than a `Category`.
private struct CollectionPreviewRow<Item: Identifiable & Hashable, Card: View>: View {
    let title: LocalizedStringKey
    let collection: LibraryCollection
    let items: [Item]
    let animationNamespace: Namespace.ID?
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                NavigationLink(value: collection) {
                    Text("Show All")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterCardMetrics.railSpacing) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            card(item)
                                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                        }
                        .posterCardButtonStyle()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: PosterCardMetrics.rowHeight)
        }
        .focusSection()
    }
}

// MARK: - Movies

/// A Movies-tab collection preview row (Recently Watched or Favorites). Renders
/// nothing when the active playlist has no matching movies.
struct MovieCollectionRow: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Query private var movies: [Movie]

    init(kind: LibraryCollection.Kind, playlistPrefix: String, animationNamespace: Namespace.ID? = nil) {
        self.kind = kind
        self.playlistPrefix = playlistPrefix
        self.animationNamespace = animationNamespace
        _movies = Query(MovieCollectionQuery.descriptor(for: kind))
    }

    private var scoped: [Movie] {
        Array(movies.filter { $0.id.hasPrefix(playlistPrefix) }.prefix(collectionPreviewLimit))
    }

    var body: some View {
        let items = scoped
        if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                collection: LibraryCollection(kind: kind, type: .vod),
                items: items,
                animationNamespace: animationNamespace,
                card: { MovieCardView(movie: $0) }
            )
        }
    }
}

/// The full grid behind a Movies collection's "Show All".
struct MovieCollectionView: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Query private var movies: [Movie]

    init(kind: LibraryCollection.Kind, playlistPrefix: String, animationNamespace: Namespace.ID? = nil) {
        self.kind = kind
        self.playlistPrefix = playlistPrefix
        self.animationNamespace = animationNamespace
        _movies = Query(MovieCollectionQuery.descriptor(for: kind))
    }

    private var scoped: [Movie] {
        movies.filter { $0.id.hasPrefix(playlistPrefix) }
    }

    var body: some View {
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: scoped,
            animationNamespace: animationNamespace,
            emptyTitle: kind.title,
            emptyIcon: kind.emptyIcon,
            emptyDescription: kind == .favorites ? "Movies you mark as favorites will appear here" : "Movies you watch will appear here",
            sortRaw: .constant(""),
            showsSortMenu: false,
            card: { MovieCardView(movie: $0) }
        )
    }
}

private enum MovieCollectionQuery {
    static func descriptor(for kind: LibraryCollection.Kind) -> FetchDescriptor<Movie> {
        switch kind {
        case .recentlyWatched:
            FetchDescriptor<Movie>(
                predicate: #Predicate { $0.lastWatchedDate != nil },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
        case .favorites:
            FetchDescriptor<Movie>(
                predicate: #Predicate { $0.isFavorite },
                sortBy: [SortDescriptor(\.name)]
            )
        }
    }
}

// MARK: - Series

/// A Series-tab collection preview row (Recently Watched or Favorites). Renders
/// nothing when the active playlist has no matching series.
struct SeriesCollectionRow: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Query private var series: [Series]

    init(kind: LibraryCollection.Kind, playlistPrefix: String, animationNamespace: Namespace.ID? = nil) {
        self.kind = kind
        self.playlistPrefix = playlistPrefix
        self.animationNamespace = animationNamespace
        _series = Query(SeriesCollectionQuery.descriptor(for: kind))
    }

    private var scoped: [Series] {
        Array(series.filter { $0.id.hasPrefix(playlistPrefix) }.prefix(collectionPreviewLimit))
    }

    var body: some View {
        let items = scoped
        if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                collection: LibraryCollection(kind: kind, type: .series),
                items: items,
                animationNamespace: animationNamespace,
                card: { SeriesCardView(series: $0) }
            )
        }
    }
}

/// The full grid behind a Series collection's "Show All".
struct SeriesCollectionView: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Query private var series: [Series]

    init(kind: LibraryCollection.Kind, playlistPrefix: String, animationNamespace: Namespace.ID? = nil) {
        self.kind = kind
        self.playlistPrefix = playlistPrefix
        self.animationNamespace = animationNamespace
        _series = Query(SeriesCollectionQuery.descriptor(for: kind))
    }

    private var scoped: [Series] {
        series.filter { $0.id.hasPrefix(playlistPrefix) }
    }

    var body: some View {
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: scoped,
            animationNamespace: animationNamespace,
            emptyTitle: kind.title,
            emptyIcon: kind.emptyIcon,
            emptyDescription: kind == .favorites ? "Series you mark as favorites will appear here" : "Series you watch will appear here",
            sortRaw: .constant(""),
            showsSortMenu: false,
            card: { SeriesCardView(series: $0) }
        )
    }
}

private enum SeriesCollectionQuery {
    static func descriptor(for kind: LibraryCollection.Kind) -> FetchDescriptor<Series> {
        switch kind {
        case .recentlyWatched:
            FetchDescriptor<Series>(
                predicate: #Predicate { $0.lastWatchedDate != nil },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
        case .favorites:
            FetchDescriptor<Series>(
                predicate: #Predicate { $0.isFavorite },
                sortBy: [SortDescriptor(\.name)]
            )
        }
    }
}

// MARK: - Title bridging

private extension LibraryCollection.Kind {
    /// `CategoryContentGrid` takes a plain `String` title (it surfaces the
    /// category name, normally already a `String`). These collections have a
    /// fixed English name we localize at the call site for the grid heading.
    var localizedTitleString: String {
        switch self {
        case .recentlyWatched: String(localized: "Recently Watched")
        case .favorites: String(localized: "Favorites")
        }
    }
}
