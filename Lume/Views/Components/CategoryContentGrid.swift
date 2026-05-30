//
//  CategoryContentGrid.swift
//  Lume
//
//  Shared grid and preview-row components used by both Movies and Series
//  category views, minimising duplication between the two.
//

import SwiftUI
import SwiftData

// MARK: - Full Category Content Grid ("Show All")

struct CategoryContentGrid<Item: Identifiable & Hashable, Card: View>: View {
    let title: String
    let items: [Item]
    let animationNamespace: Namespace.ID?
    let emptyTitle: String
    let emptyIcon: String
    let emptyDescription: String
    @Binding var sortRaw: String
    @ViewBuilder let card: (Item) -> Card

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            card(item)
                                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ContentSortMenu(sortRaw: $sortRaw)
            }
        }
    }
}

// MARK: - Category Preview Row

struct CategoryPreviewRow<Item: Identifiable & Hashable, Card: View>: View {
    let category: Category
    let items: [Item]
    let animationNamespace: Namespace.ID?
    let emptyMessage: String
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
                    LazyHStack(spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                card(item)
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
            var descriptor = FetchDescriptor<Movie>(
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
            var descriptor = FetchDescriptor<Series>(
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
    let categories = try! container.mainContext.fetch(FetchDescriptor<Category>())
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
    let categories = try! container.mainContext.fetch(FetchDescriptor<Category>())
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
