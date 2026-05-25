//
//  SeriesView.swift
//  Lume
//
//  Main view for browsing TV series. Each category shows a preview row;
//  "Show All" navigates to the full category view.
//

import SwiftUI
import SwiftData

struct SeriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "series" && $0.isHidden == false })
    private var categories: [Category]

    @State private var selectedPlaylist: Playlist?
    @State private var showingSync = false

    @AppStorage(SortStorageKey.seriesCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private let previewLimit = 20

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "tv",
                        description: Text("Add a playlist in Settings to start browsing series")
                    )
                } else if categories.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Series",
                            systemImage: "tv.fill",
                            description: Text("Sync your playlist to load TV series")
                        )

                        if let playlist = playlists.first {
                            Button {
                                selectedPlaylist = playlist
                                showingSync = true
                            } label: {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                            ForEach(sortedCategories) { category in
                                SeriesCategoryPreview(category: category, limit: previewLimit, sort: contentSort)
                                    .id("\(category.id)-\(contentSort.rawValue)")
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Series")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if let playlist = playlists.first {
                        Menu {
                            ForEach(playlists) { p in
                                Button {
                                    selectedPlaylist = p
                                } label: {
                                    Label(p.name, systemImage: selectedPlaylist?.id == p.id ? "checkmark" : "")
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedPlaylist?.name ?? playlist.name)
                                    .font(.headline)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                        }
                    }
                }

                ToolbarItem(placement: .automatic) {
                    SortMenu(
                        categorySortRaw: $categorySortRaw,
                        contentSortRaw: $contentSortRaw
                    )
                }

                ToolbarItem(placement: .automatic) {
                    HStack {
                        Button {
                            showingSync = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }

                        Button {
                            // Search action
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .task {
                if selectedPlaylist == nil, let first = playlists.first {
                    selectedPlaylist = first
                }
            }
            .sheet(isPresented: $showingSync) {
                if let playlist = selectedPlaylist ?? playlists.first {
                    SyncProgressView(playlist: playlist, isPresented: $showingSync)
                }
            }
            .navigationDestination(for: Category.self) { category in
                SeriesCategoryView(category: category, sort: contentSort)
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series)
            }
        }
    }

    private var sortedCategories: [Category] {
        categorySort.sort(categories)
    }
}

// MARK: - Category Preview Row

struct SeriesCategoryPreview: View {
    let category: Category
    @Query private var series: [Series]

    init(category: Category, limit: Int, sort: ContentSortOption) {
        self.category = category
        let categoryId = category.id
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate<Series> { $0.categoryId == categoryId },
            sortBy: sort.seriesDescriptors
        )
        descriptor.fetchLimit = limit
        _series = Query(descriptor)
    }

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

            if series.isEmpty {
                Text("No series in this category")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(series) { item in
                            NavigationLink(value: item) {
                                SeriesCardView(series: item)
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

// MARK: - Full Category View (Show All)

struct SeriesCategoryView: View {
    let category: Category
    @Query private var series: [Series]

    init(category: Category, sort: ContentSortOption) {
        self.category = category
        let categoryId = category.id
        _series = Query(
            filter: #Predicate<Series> { $0.categoryId == categoryId },
            sort: sort.seriesDescriptors
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            if series.isEmpty {
                ContentUnavailableView(
                    "No Series",
                    systemImage: "tv.fill",
                    description: Text("This category has no series")
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(series) { item in
                        NavigationLink(value: item) {
                            SeriesCardView(series: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(category.name)
    }
}

#Preview {
    SeriesView()
        .modelContainer(for: Playlist.self, inMemory: true)
}
