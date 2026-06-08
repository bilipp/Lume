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

// MARK: - Category Preview Row

struct CategoryPreviewRow<Item: Identifiable & Hashable, Card: View>: View {
    let category: Category
    let items: [Item]
    let animationNamespace: Namespace.ID?
    let emptyMessage: LocalizedStringKey
    @ViewBuilder let card: (Item) -> Card

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
        CategoryPreviewRow(
            category: category,
            items: movies,
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
        CategoryPreviewRow(
            category: category,
            items: series,
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
