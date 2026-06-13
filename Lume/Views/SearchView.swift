//
//  SearchView.swift
//  Lume
//
//  Global search across all content
//

import SwiftData
import SwiftUI

struct SearchView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedFilter: ContentFilter = .all
    @State private var results: [SearchResult] = []
    @State private var playingMedia: PlayableMedia?

    /// Max matches fetched per content type. Keeps the result set bounded so the
    /// list stays responsive even when a playlist holds tens of thousands of items.
    private let resultLimit = 50

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Search for movies, series, or live TV channels")
                    )
                } else {
                    // Filter Picker
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(ContentFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    // Results — only show "No Results" once a query has actually
                    // been run, so it doesn't flash while the input is debouncing.
                    if results.isEmpty {
                        if !debouncedSearchText.isEmpty {
                            ContentUnavailableView.search
                        }
                    } else {
                        Section {
                            ForEach(results) { result in
                                switch result {
                                case let .movie(movie):
                                    NavigationLink(value: movie) {
                                        SearchResultRow(result: result)
                                            .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                                    }
                                case let .series(series):
                                    NavigationLink(value: series) {
                                        SearchResultRow(result: result)
                                            .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                                    }
                                case let .liveStream(stream):
                                    Button {
                                        playChannel(stream)
                                    } label: {
                                        SearchResultRow(result: result)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text("\(results.count) Results")
                        }
                    }
                }
            }
            .platformNavigationTitle("Search")
            .searchable(text: $searchText, prompt: "Movies, Series, Live TV...")
            #if os(iOS)
                .searchToolbarBehavior(.minimize)
            #endif
                .navigationDestination(for: Movie.self) { movie in
                    MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                    #if os(iOS)
                        .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
                    #endif
                }
                .navigationDestination(for: Series.self) { series in
                    SeriesDetailView(series: series, animationNamespace: animationNamespace)
                    #if os(iOS)
                        .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
                    #endif
                }
                .task(id: searchText) {
                    // Debounce raw keystrokes. .task(id:) cancels the in-flight task
                    // (including this sleep) the instant searchText changes, so the
                    // fetch below only fires once typing actually pauses.
                    let trimmed = trimmedQuery
                    guard !trimmed.isEmpty else {
                        debouncedSearchText = ""
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = trimmed
                }
                .task(id: SearchKey(text: debouncedSearchText, filter: selectedFilter)) {
                    // Re-run whenever the settled query or the filter changes.
                    // Filter changes are instant (no debounce on the segmented control).
                    updateResults()
                }
        }
        #if os(iOS)
        .fullScreenCover(item: $playingMedia) { media in
            FullScreenPlayerView(media: media)
        }
        #endif
    }

    // MARK: - Playback

    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    private func playChannel(_ stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }

    // MARK: - Searching

    /// Runs the search against SwiftData using bounded, predicate-based fetches.
    ///
    /// Filtering happens in SQLite (via `localizedStandardContains`) instead of
    /// loading every Movie/Series/LiveStream into memory and scanning on the main
    /// thread. Combined with the debounce above, this keeps typing smooth no matter
    /// how large the library is — the work runs once, after input settles, and
    /// returns at most `resultLimit` rows per content type.
    @MainActor
    private func updateResults() {
        let query = debouncedSearchText
        guard !query.isEmpty else {
            results = []
            return
        }

        var matches: [SearchResult] = []

        if selectedFilter == .all || selectedFilter == .movies {
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.name.localizedStandardContains(query) },
                sortBy: [SortDescriptor(\.name)]
            )
            descriptor.fetchLimit = resultLimit
            let movies = (try? modelContext.fetch(descriptor)) ?? []
            matches.append(contentsOf: movies.map { .movie($0) })
        }

        if selectedFilter == .all || selectedFilter == .series {
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.name.localizedStandardContains(query) },
                sortBy: [SortDescriptor(\.name)]
            )
            descriptor.fetchLimit = resultLimit
            let series = (try? modelContext.fetch(descriptor)) ?? []
            matches.append(contentsOf: series.map { .series($0) })
        }

        if selectedFilter == .all || selectedFilter == .liveTV {
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.name.localizedStandardContains(query) },
                sortBy: [SortDescriptor(\.name)]
            )
            descriptor.fetchLimit = resultLimit
            let streams = (try? modelContext.fetch(descriptor)) ?? []
            matches.append(contentsOf: streams.map { .liveStream($0) })
        }

        results = matches
    }
}

// MARK: - Search Key

/// Identity for the fetch task: re-run when either the settled query text or the
/// active content filter changes.
private struct SearchKey: Equatable {
    let text: String
    let filter: ContentFilter
}

// MARK: - Content Filter

enum ContentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case series = "Series"
    case liveTV = "Live TV"

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// MARK: - Search Result

enum SearchResult: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)
    case liveStream(LiveStream)

    var id: String {
        switch self {
        case let .movie(movie):
            "movie-\(movie.id)"
        case let .series(series):
            "series-\(series.id)"
        case let .liveStream(stream):
            "live-\(stream.id)"
        }
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            CachedAsyncImage(url: thumbnailURL, maxPixelSize: 90) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            ProgressView()
                        }
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: iconName)
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: categoryIcon)
                    Text(LocalizedStringKey(categoryName))
                }
                .font(.caption2)
                .foregroundStyle(.blue)
            }

            Spacer()
        }
    }

    private var thumbnailURL: URL? {
        switch result {
        case let .movie(movie):
            URL(string: movie.streamIcon ?? "")
        case let .series(series):
            URL(string: series.cover ?? "")
        case let .liveStream(stream):
            URL(string: stream.streamIcon ?? "")
        }
    }

    private var title: String {
        switch result {
        case let .movie(movie):
            movie.name
        case let .series(series):
            series.name
        case let .liveStream(stream):
            stream.name
        }
    }

    private var subtitle: String {
        switch result {
        case let .movie(movie):
            movie.genre ?? movie.releaseDate ?? ""
        case let .series(series):
            series.genre ?? series.releaseDate ?? ""
        case .liveStream:
            "Live"
        }
    }

    private var categoryName: String {
        switch result {
        case .movie:
            "Movie"
        case .series:
            "Series"
        case .liveStream:
            "Live TV"
        }
    }

    private var categoryIcon: String {
        switch result {
        case .movie:
            "film"
        case .series:
            "tv"
        case .liveStream:
            "antenna.radiowaves.left.and.right"
        }
    }

    private var iconName: String {
        switch result {
        case .movie:
            "film"
        case .series:
            "tv"
        case .liveStream:
            "antenna.radiowaves.left.and.right"
        }
    }
}

#Preview("Empty") {
    SearchView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    SearchView()
        .modelContainer(previewContainer())
}
