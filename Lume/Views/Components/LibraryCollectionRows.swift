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
        case recentlyAdded

        var title: LocalizedStringKey {
            switch self {
            case .recentlyWatched: "Recently Watched"
            case .favorites: "Favorites"
            case .recentlyAdded: "Recently Added"
            }
        }

        var emptyIcon: String {
            switch self {
            case .recentlyWatched: "clock.arrow.circlepath"
            case .favorites: "heart"
            case .recentlyAdded: "sparkles"
            }
        }
    }

    let kind: Kind
    let type: CategoryType
}

/// How many items each preview row shows before "Show All".
private let collectionPreviewLimit = 20

/// Upper bound on the "Recently Added" fetch. Recently Watched and Favorites
/// match small subsets, but every title carries an `added` timestamp, so that
/// predicate matches the whole library — an unbounded fetch would hydrate the
/// entire catalog on every change and stutter badly during sync. We only ever
/// surface the newest slice, so the query is capped (then scoped in-memory to
/// the active playlist, like the rest of the app).
private let recentlyAddedFetchLimit = 200

// MARK: - Shared preview row

/// A titled horizontal rail with a trailing "Show All" link into the full
/// collection grid. Mirrors `CategoryPreviewRow`, but its header is a plain
/// title plus a `LibraryCollection` destination rather than a `Category`.
private struct CollectionPreviewRow<Item: Identifiable & Hashable, Card: View>: View {
    let title: LocalizedStringKey
    let collection: LibraryCollection
    let items: [Item]
    /// Whether the full collection holds more items than this preview shows.
    /// When false, the "Show All" link is hidden — there's nothing more to see.
    let hasMore: Bool
    let animationNamespace: Namespace.ID?
    /// When set, each card gains a destructive "Remove from Recently Watched"
    /// context menu (a long-press on the focused card on tvOS). Nil for rows
    /// where removal doesn't apply, e.g. Favorites.
    var removeAction: ((Item) -> Void)?
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                Spacer()

                if hasMore {
                    NavigationLink(value: collection) {
                        Text("Show All")
                            .font(.subheadline)
                    }
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
                        .recentlyWatchedRemoveMenu(removeAction.map { action in { action(item) } })
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: PosterCardMetrics.rowHeight)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

// MARK: - Movies

/// A Movies-tab collection preview row (Recently Watched or Favorites). Renders
/// nothing when the active playlist has no matching movies.
struct MovieCollectionRow: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
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
        let matches = scoped
        let items = Array(matches.prefix(collectionPreviewLimit))
        if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                collection: LibraryCollection(kind: kind, type: .vod),
                items: items,
                hasMore: matches.count > items.count,
                animationNamespace: animationNamespace,
                removeAction: kind == .recentlyWatched ? { movie in
                    movie.lastWatchedDate = nil
                    try? modelContext.save()
                } : nil,
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
        let emptyDescription: LocalizedStringKey = switch kind {
        case .favorites: "Movies you mark as favorites will appear here"
        case .recentlyWatched: "Movies you watch will appear here"
        case .recentlyAdded: "Movies recently added to your library will appear here"
        }
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: scoped,
            animationNamespace: animationNamespace,
            emptyTitle: kind.title,
            emptyIcon: kind.emptyIcon,
            emptyDescription: emptyDescription,
            sortRaw: .constant(""),
            showsSortMenu: false,
            card: { MovieCardView(movie: $0) }
        )
    }
}

private enum MovieCollectionQuery {
    static func descriptor(for kind: LibraryCollection.Kind) -> FetchDescriptor<Movie> {
        var descriptor = switch kind {
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
        case .recentlyAdded:
            FetchDescriptor<Movie>(
                predicate: #Predicate { $0.added != nil },
                sortBy: [SortDescriptor(\.added, order: .reverse), SortDescriptor(\.num)]
            )
        }
        if kind == .recentlyAdded { descriptor.fetchLimit = recentlyAddedFetchLimit }
        return descriptor
    }
}

// MARK: - Series

/// A Series-tab collection preview row (Recently Watched or Favorites). Renders
/// nothing when the active playlist has no matching series.
struct SeriesCollectionRow: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
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
        let matches = scoped
        let items = Array(matches.prefix(collectionPreviewLimit))
        if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                collection: LibraryCollection(kind: kind, type: .series),
                items: items,
                hasMore: matches.count > items.count,
                animationNamespace: animationNamespace,
                removeAction: kind == .recentlyWatched ? { series in
                    series.lastWatchedDate = nil
                    try? modelContext.save()
                } : nil,
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
        let emptyDescription: LocalizedStringKey = switch kind {
        case .favorites: "Series you mark as favorites will appear here"
        case .recentlyWatched: "Series you watch will appear here"
        case .recentlyAdded: "Series recently added to your library will appear here"
        }
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: scoped,
            animationNamespace: animationNamespace,
            emptyTitle: kind.title,
            emptyIcon: kind.emptyIcon,
            emptyDescription: emptyDescription,
            sortRaw: .constant(""),
            showsSortMenu: false,
            card: { SeriesCardView(series: $0) }
        )
    }
}

private enum SeriesCollectionQuery {
    static func descriptor(for kind: LibraryCollection.Kind) -> FetchDescriptor<Series> {
        var descriptor = switch kind {
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
        case .recentlyAdded:
            FetchDescriptor<Series>(
                predicate: #Predicate { $0.lastModified != nil },
                sortBy: [SortDescriptor(\.lastModified, order: .reverse), SortDescriptor(\.num)]
            )
        }
        if kind == .recentlyAdded { descriptor.fetchLimit = recentlyAddedFetchLimit }
        return descriptor
    }
}

// MARK: - Remove-from-recents menu

extension View {
    /// Attaches a destructive "Remove from Recently Watched" context menu when an
    /// action is provided, otherwise leaves the view untouched. Surfaced by a
    /// long-press on the focused card on tvOS (and on iOS), or a right-click on
    /// macOS — the standard cross-platform secondary-action gesture.
    @ViewBuilder
    func recentlyWatchedRemoveMenu(_ remove: (() -> Void)?) -> some View {
        if let remove {
            contextMenu {
                Button(role: .destructive, action: remove) {
                    Label("Remove from Recently Watched", systemImage: "clock.badge.xmark")
                }
            }
        } else {
            self
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
        case .recentlyAdded: String(localized: "Recently Added")
        }
    }
}
