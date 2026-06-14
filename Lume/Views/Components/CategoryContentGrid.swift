//
//  CategoryContentGrid.swift
//  Lume
//
//  Shared grid and preview-row components used by both Movies and Series
//  category views, minimising duplication between the two.
//

import SwiftData
import SwiftUI

// MARK: - Full Category Content Grid ("Show All")

struct CategoryContentGrid<Item: Identifiable & Hashable, Card: View>: View {
    let title: String
    let items: [Item]
    let animationNamespace: Namespace.ID?
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let emptyDescription: LocalizedStringKey
    @Binding var sortRaw: String
    /// Whether to surface the content sort menu. Categories are user-sortable;
    /// the Favorites / Recently Watched collections have an intrinsic order
    /// (alphabetical / most-recent-first) and pass `false` to hide it.
    var showsSortMenu: Bool = true
    @ViewBuilder let card: (Item) -> Card

    private let columns = [GridItem(.adaptive(minimum: PosterCardMetrics.gridMinimum), spacing: PosterCardMetrics.gridSpacing)]

    var body: some View {
        ScrollView {
            // tvOS suppresses the system navigation title (it renders centred and
            // the tab bar only shows the section, not the category), so we surface
            // the category name as a leading-aligned heading in the content itself.
            #if os(tvOS)
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 40)
            #endif

            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: PosterCardMetrics.gridSpacing) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            card(item)
                                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                        }
                        .posterCardButtonStyle()
                    }
                }
                .padding()
            }
        }
        // tvOS surfaces sorting through the tab bar's library controls instead of a
        // toolbar, mirroring the main browse views.
        #if !os(tvOS)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ContentSortMenu(sortRaw: $sortRaw)
            }
        }
        #endif
    }
}

// MARK: - Category Grid ("Show All" tiles)

/// A grid of lightweight, query-free category tiles shown beneath the inline
/// preview rows. Each tile behaves exactly like a row's "Show All" link,
/// navigating to that category's full grid via `NavigationLink(value:)`.
///
/// Only the first few categories render as inline preview rows — every preview
/// row carries its own live `@Query`, so a playlist with dozens of categories
/// would otherwise spin up dozens of concurrent fetches and stutter the browse
/// screen. Surfacing the long tail as plain name tiles keeps it fast.
struct CategoryGridSection: View {
    let title: LocalizedStringKey
    let categories: [Category]

    private let columns = [GridItem(.adaptive(minimum: CategoryTileMetrics.minimum), spacing: CategoryTileMetrics.spacing)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: CategoryTileMetrics.spacing) {
                ForEach(categories) { category in
                    NavigationLink(value: category) {
                        CategoryTile(name: category.name)
                    }
                    .posterCardButtonStyle()
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct CategoryTile: View {
    let name: String

    // On the 10-foot UI the focus engine owns selection feedback: the focused
    // tile brightens to a solid plate with dark text (the standard tvOS card
    // affordance), while the rest sit on a quiet material. `isFocused` is set
    // for the focused button's label subtree, which is where this tile renders.
    #if os(tvOS)
        @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        Text(name)
            .font(CategoryTileMetrics.font)
            .fontWeight(.semibold)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: CategoryTileMetrics.height)
            .padding(.horizontal)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: CategoryTileMetrics.cornerRadius, style: .continuous))
        #if os(tvOS)
            // Animate the brighten in lockstep with the focus scale supplied
            // by TVCardButtonStyle so the plate and text don't pop.
            .animation(.easeOut(duration: 0.18), value: isFocused)
        #endif
    }

    private var foreground: Color {
        #if os(tvOS)
            isFocused ? .black : .primary
        #else
            .primary
        #endif
    }

    @ViewBuilder
    private var background: some View {
        #if os(tvOS)
            // A solid white layer crossfaded over the resting material — keeping
            // both layers present (rather than swapping view identity) lets the
            // focus transition interpolate cleanly.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.white.opacity(isFocused ? 1 : 0))
        #else
            Rectangle().fill(.ultraThinMaterial)
        #endif
    }
}

private enum CategoryTileMetrics {
    #if os(tvOS)
        static let minimum: CGFloat = 320
        static let spacing: CGFloat = 36
        static let height: CGFloat = 100
        static let cornerRadius: CGFloat = 12
        /// `.title3` (~38pt on tvOS) overwhelms a name tile; a tighter fixed size
        /// reads cleanly beside the poster cards and matches their title weight.
        static let font: Font = .system(size: 26, weight: .semibold)
    #else
        static let minimum: CGFloat = 160
        static let spacing: CGFloat = 16
        static let height: CGFloat = 72
        static let cornerRadius: CGFloat = 10
        static let font: Font = .subheadline
    #endif
}

// MARK: - Category Preview Row

struct CategoryPreviewRow<Item: Identifiable & Hashable, Card: View>: View {
    let category: Category
    let items: [Item]
    /// Whether the category holds more items than this preview shows. When false,
    /// the "Show All" link is hidden — there's nothing more to see.
    let hasMore: Bool
    let animationNamespace: Namespace.ID?
    let emptyMessage: LocalizedStringKey
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.name)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                Spacer()

                if hasMore {
                    NavigationLink(value: category) {
                        Text("Show All")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            if items.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
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
        }
    }
}

// MARK: - Movie Category View

struct MovieCategoryView: View {
    let category: Category
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    @State private var movies: [Movie] = []

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    var body: some View {
        CategoryContentGrid(
            title: category.name,
            items: movies,
            animationNamespace: animationNamespace,
            emptyTitle: "No Movies",
            emptyIcon: "film.stack",
            emptyDescription: "This category has no movies",
            sortRaw: $contentSortRaw,
            card: { MovieCardView(movie: $0) }
        )
        .task(id: contentSortRaw) {
            let categoryId = category.id
            let descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.categoryId == categoryId },
                sortBy: contentSort.movieDescriptors
            )
            movies = (try? modelContext.fetch(descriptor)) ?? []
        }
    }
}

// MARK: - Movie Category Preview

struct MovieCategoryPreview: View {
    let category: Category
    private let limit: Int
    @Query private var movies: [Movie]
    var animationNamespace: Namespace.ID?

    init(category: Category, limit: Int, sort: ContentSortOption, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.limit = limit
        self.animationNamespace = animationNamespace
        let categoryId = category.id
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate<Movie> { $0.categoryId == categoryId },
            sortBy: sort.movieDescriptors
        )
        // Fetch one extra so we can tell whether a full grid would show more.
        descriptor.fetchLimit = limit + 1
        _movies = Query(descriptor)
    }

    var body: some View {
        CategoryPreviewRow(
            category: category,
            items: Array(movies.prefix(limit)),
            hasMore: movies.count > limit,
            animationNamespace: animationNamespace,
            emptyMessage: "No movies in this category",
            card: { MovieCardView(movie: $0) }
        )
    }
}

// MARK: - Series Category View

struct SeriesCategoryView: View {
    let category: Category
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    @State private var series: [Series] = []

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    var body: some View {
        CategoryContentGrid(
            title: category.name,
            items: series,
            animationNamespace: animationNamespace,
            emptyTitle: "No Series",
            emptyIcon: "tv.fill",
            emptyDescription: "This category has no series",
            sortRaw: $contentSortRaw,
            card: { SeriesCardView(series: $0) }
        )
        .task(id: contentSortRaw) {
            let categoryId = category.id
            let descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.categoryId == categoryId },
                sortBy: contentSort.seriesDescriptors
            )
            series = (try? modelContext.fetch(descriptor)) ?? []
        }
    }
}

// MARK: - Series Category Preview

struct SeriesCategoryPreview: View {
    let category: Category
    private let limit: Int
    @Query private var series: [Series]
    var animationNamespace: Namespace.ID?

    init(category: Category, limit: Int, sort: ContentSortOption, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.limit = limit
        self.animationNamespace = animationNamespace
        let categoryId = category.id
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate<Series> { $0.categoryId == categoryId },
            sortBy: sort.seriesDescriptors
        )
        // Fetch one extra so we can tell whether a full grid would show more.
        descriptor.fetchLimit = limit + 1
        _series = Query(descriptor)
    }

    var body: some View {
        CategoryPreviewRow(
            category: category,
            items: Array(series.prefix(limit)),
            hasMore: series.count > limit,
            animationNamespace: animationNamespace,
            emptyMessage: "No series in this category",
            card: { SeriesCardView(series: $0) }
        )
    }
}

// MARK: - Previews

#Preview("Movie Category Grid") {
    let container = previewContainer()
    let categories = (try? container.mainContext.fetch(FetchDescriptor<Category>())) ?? []
    let category = categories.first { $0.typeRaw == "vod" } ?? categories[0]
    return NavigationStack {
        MovieCategoryView(category: category, animationNamespace: nil)
    }
    .modelContainer(container)
}

#Preview("Movie Category Empty") {
    let container = previewContainer()
    let emptyCategory = Category(apiId: "999", name: "Empty Category", parentId: 0, type: .vod, playlist: PreviewData.samplePlaylist)
    return NavigationStack {
        MovieCategoryView(category: emptyCategory, animationNamespace: nil)
    }
    .modelContainer(container)
}

#Preview("Series Category Grid") {
    let container = previewContainer()
    let categories = (try? container.mainContext.fetch(FetchDescriptor<Category>())) ?? []
    let category = categories.first { $0.typeRaw == "series" } ?? categories[0]
    return NavigationStack {
        SeriesCategoryView(category: category, animationNamespace: nil)
    }
    .modelContainer(container)
}

#Preview("Series Category Empty") {
    let container = previewContainer()
    let emptyCategory = Category(apiId: "998", name: "Empty Series", parentId: 0, type: .series, playlist: PreviewData.samplePlaylist)
    return NavigationStack {
        SeriesCategoryView(category: emptyCategory, animationNamespace: nil)
    }
    .modelContainer(container)
}
