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
    @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
    private var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault

    @State private var series: [Series] = []
    /// State of the loaded titles' other copies — see `MovieCategoryView`.
    @State private var groupStates: [String: TitleGroupState] = [:]
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

    /// The sort and grouping the loaded pages were fetched for.
    private var loadKey: String {
        "\(contentSortRaw)|\(groupDuplicateTitles)"
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
            .task(id: loadKey) {
                guard loadedSort != loadKey else {
                    refreshGroupStates()
                    return
                }
                loadedSort = loadKey
                series = []
                groupStates = [:]
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
            favoriteMenu: CategoryFavoriteMenu(
                isFavorite: { TitleGroupStateLookup.state(of: $0, in: groupStates).isFavorite },
                toggle: { toggleFavorite($0) }
            ),
            card: { series in
                SeriesCardView(series: series, fillsWidth: true)
            }
        )
        .environment(\.titleGroupStates, TitleGroupStates(series: groupStates))
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
        var descriptor = CategoryGridQuery.series(
            categoryId: category.id,
            grouped: groupDuplicateTitles,
            sortBy: contentSort.seriesDescriptors
        )
        descriptor.fetchOffset = series.count
        descriptor.fetchLimit = pageSize
        let page = (try? modelContext.fetch(descriptor)) ?? []
        series.append(contentsOf: page)
        if page.count < pageSize { canLoadMore = false }
        let keys = page.compactMap(\.titleGroupKey)
        groupStates.replace(keys: keys, with: TitleGroupStateLookup.series(keys: keys, in: modelContext))
    }

    private func refreshGroupStates() {
        groupStates = TitleGroupStateLookup.states(of: series, in: modelContext)
    }

    private func toggleFavorite(_ series: Series) {
        TitleGroupFavorites.toggle(series, updating: &groupStates, in: modelContext)
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
        groupStates = [:]
        canLoadMore = true
        loadNextPage()
    }

    /// Re-fetches the already-loaded window in place — see
    /// `MovieCategoryView.reloadLoadedPages`.
    private func reloadLoadedPages() {
        var descriptor = CategoryGridQuery.series(
            categoryId: category.id,
            grouped: groupDuplicateTitles,
            sortBy: contentSort.seriesDescriptors
        )
        let window = max(series.count, pageSize)
        descriptor.fetchLimit = window
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        canLoadMore = rows.count == window
        series = rows
        refreshGroupStates()
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
    @Environment(\.modelContext) private var modelContext
    @State private var groupStates: [String: TitleGroupState] = [:]

    /// - Parameter grouped: see `MovieCategoryPreview`.
    init(category: Category, limit: Int, sort: ContentSortOption, grouped: Bool, animationNamespace: Namespace.ID? = nil) {
        self.category = category
        self.limit = limit
        self.animationNamespace = animationNamespace
        var descriptor = CategoryGridQuery.series(categoryId: category.id, grouped: grouped, sortBy: sort.seriesDescriptors)
        // Fetch one extra so we can tell whether a full grid would show more.
        descriptor.fetchLimit = limit + 1
        _series = Query(descriptor)
    }

    var body: some View {
        let shown = Array(series.prefix(limit))
        CategoryPreviewRow(
            category: category,
            items: shown,
            hasMore: series.count > limit,
            animationNamespace: animationNamespace,
            emptyMessage: "No series in this category",
            favoriteMenu: CategoryFavoriteMenu(
                isFavorite: { TitleGroupStateLookup.state(of: $0, in: groupStates).isFavorite },
                toggle: { toggleFavorite($0) }
            ),
            card: { series in
                SeriesCardView(series: series)
            }
        )
        .environment(\.titleGroupStates, TitleGroupStates(series: groupStates))
        .task(id: shown.compactMap(\.titleGroupKey)) {
            groupStates = TitleGroupStateLookup.states(of: shown, in: modelContext)
        }
    }

    private func toggleFavorite(_ series: Series) {
        TitleGroupFavorites.toggle(series, updating: &groupStates, in: modelContext)
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
