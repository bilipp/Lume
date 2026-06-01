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
    @Query private var movies: [Movie]
    @Query private var series: [Series]
    @Query private var liveStreams: [LiveStream]
    @Query private var playlists: [Playlist]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedFilter: ContentFilter = .all
    @State private var searchTask: Task<Void, Never>?
    @State private var playingMedia: PlayableMedia?

    var body: some View {
        NavigationStack {
            List {
                if debouncedSearchText.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Search for movies, series, or live TV channels")
                    )
                } else {
                    // Filter Picker
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(ContentFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    // Results
                    if filteredResults.isEmpty {
                        ContentUnavailableView.search
                    } else {
                        Section {
                            ForEach(filteredResults) { result in
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
                            Text("\(filteredResults.count) Results")
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
                .onChange(of: searchText) { _, newValue in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        debouncedSearchText = newValue
                    }
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
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }

    private var filteredResults: [SearchResult] {
        var results: [SearchResult] = []

        let query = debouncedSearchText.lowercased()

        // Movies
        if selectedFilter == .all || selectedFilter == .movies {
            let matchingMovies = movies.filter { movie in
                movie.name.lowercased().contains(query)
            }
            results.append(contentsOf: matchingMovies.map { .movie($0) })
        }

        // Series
        if selectedFilter == .all || selectedFilter == .series {
            let matchingSeries = series.filter { entry in
                entry.name.lowercased().contains(query)
            }
            results.append(contentsOf: matchingSeries.map { .series($0) })
        }

        // Live Streams
        if selectedFilter == .all || selectedFilter == .liveTV {
            let matchingStreams = liveStreams.filter { stream in
                stream.name.lowercased().contains(query)
            }
            results.append(contentsOf: matchingStreams.map { .liveStream($0) })
        }

        return results
    }
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
            AsyncImage(url: thumbnailURL) { phase in
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
                    Text(categoryName)
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
