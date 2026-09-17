//
//  SeriesCategoryView.swift
//  Lume
//
//  The concrete Series category screens — the full "Show All" grid and the
//  home-screen preview row — built on the shared components in
//  CategoryContentGrid.swift.
//

import SwiftData
import SwiftUI

// MARK: - Series Category View

struct SeriesCategoryView: View {
    let category: Category
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    @State private var series: [Series] = []
    @State private var canLoadMore = true
    @State private var isLoadingPage = false
    /// True while a Stalker category's content is being fetched from the portal
    /// on first open — drives the loading overlay.
    @State private var isImporting = false
    /// Sort the current pages were loaded for; reload only on change so a pop
    /// back from a detail keeps the loaded pages and scroll position intact.
    @State private var loadedSort: String?

    /// A category in a large IPTV playlist can hold thousands of titles; fetch a
    /// page at a time and load the next as the grid nears the end, rather than
    /// hydrating the whole category into memory at once.
    private let pageSize = 100

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    /// The playlist when it's a Stalker portal, whose categories are imported
    /// on demand rather than synced whole.
    private var stalkerPlaylist: Playlist? {
        guard let playlist = category.playlist, playlist.sourceType == .stalker else { return nil }
        return playlist
    }

    var body: some View {
        grid
            .overlay {
                if isImporting, series.isEmpty {
                    ProgressView("Loading…")
                }
            }
            .task(id: contentSortRaw) {
                guard loadedSort != contentSortRaw else { return }
                loadedSort = contentSortRaw
                series = []
                canLoadMore = true
                await importStalkerContentIfNeeded()
                loadNextPage()
                await revalidateStalkerContentIfStale()
            }
    }

    @ViewBuilder
    private var grid: some View {
        let base = CategoryContentGrid(
            title: category.name,
            items: series,
            animationNamespace: animationNamespace,
            emptyTitle: "No Series",
            emptyIcon: "tv.fill",
            emptyDescription: "This category has no series",
            sortRaw: $contentSortRaw,
            onLoadMore: { loadNextPage() },
            card: { SeriesCardView(series: $0, fillsWidth: true) }
        )
        // Pull-to-refresh re-imports a Stalker category — see `MovieCategoryView`.
        #if !os(tvOS)
            if stalkerPlaylist != nil {
                base.refreshable { await reimportStalkerContent() }
            } else {
                base
            }
        #else
            base
        #endif
    }

    private func loadNextPage() {
        guard canLoadMore, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let categoryId = category.id
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: contentSort.seriesDescriptors
        )
        descriptor.fetchOffset = series.count
        descriptor.fetchLimit = pageSize
        let page = (try? modelContext.fetch(descriptor)) ?? []
        series.append(contentsOf: page)
        if page.count < pageSize { canLoadMore = false }
    }

    /// Imports the category from the portal the first time it's opened (Stalker
    /// only; other sources are already fully synced).
    private func importStalkerContentIfNeeded() async {
        guard let playlist = stalkerPlaylist, category.contentImportedAt == nil else { return }
        await runStalkerImport(playlist: playlist)
    }

    /// Background revalidation of content older than `Category.stalkerContentTTL`
    /// — see `MovieCategoryView.revalidateStalkerContentIfStale`.
    private func revalidateStalkerContentIfStale() async {
        guard let playlist = stalkerPlaylist,
              category.contentImportedAt != nil, category.stalkerContentStale else { return }
        await runStalkerImport(playlist: playlist)
        reloadLoadedPages()
    }

    private func reimportStalkerContent() async {
        guard let playlist = stalkerPlaylist else { return }
        await runStalkerImport(playlist: playlist)
        series = []
        canLoadMore = true
        loadNextPage()
    }

    /// Re-fetches the already-loaded window in place — see
    /// `MovieCategoryView.reloadLoadedPages`.
    private func reloadLoadedPages() {
        let categoryId = category.id
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: contentSort.seriesDescriptors
        )
        let window = max(series.count, pageSize)
        descriptor.fetchLimit = window
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        canLoadMore = rows.count == window
        series = rows
    }

    private func runStalkerImport(playlist: Playlist) async {
        isImporting = true
        defer { isImporting = false }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        _ = try? await manager.importStalkerCategory(apiId: category.apiId, type: .series, playlist: playlist)
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
