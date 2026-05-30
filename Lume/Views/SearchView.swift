//
//  SearchView.swift
//  Lume
//
//  Global search across all content
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Query private var movies: [Movie]
    @Query private var series: [Series]
    @Query private var liveStreams: [LiveStream]

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedFilter: ContentFilter = .all
    @State private var searchTask: Task<Void, Never>?

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
                                case .movie(let movie):
                                    NavigationLink(value: movie) {
                                        SearchResultRow(result: result)
                                            .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                                    }
                                case .series(let series):
                                    NavigationLink(value: series) {
                                        SearchResultRow(result: result)
                                            .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                                    }
                                case .liveStream(let stream):
                                    NavigationLink(value: stream) {
                                        SearchResultRow(result: result)
                                    }
                                }
                            }
                        } header: {
                            Text("\(filteredResults.count) Results")
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: "Movies, Series, Live TV...")
            .searchToolbarBehavior(.minimize)
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: animationNamespace)
                    .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
            }
            .navigationDestination(for: LiveStream.self) { stream in
                Text("Live Stream: \(stream.name)")
                    // TODO: Live stream detail view
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
            let matchingSeries = series.filter { s in
                s.name.lowercased().contains(query)
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

    var id: String { rawValue }
}

// MARK: - Search Result

enum SearchResult: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)
    case liveStream(LiveStream)

    var id: String {
        switch self {
        case .movie(let movie):
            return "movie-\(movie.id)"
        case .series(let series):
            return "series-\(series.id)"
        case .liveStream(let stream):
            return "live-\(stream.id)"
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
                case .success(let image):
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
        case .movie(let movie):
            return URL(string: movie.streamIcon ?? "")
        case .series(let series):
            return URL(string: series.cover ?? "")
        case .liveStream(let stream):
            return URL(string: stream.streamIcon ?? "")
        }
    }

    private var title: String {
        switch result {
        case .movie(let movie):
            return movie.name
        case .series(let series):
            return series.name
        case .liveStream(let stream):
            return stream.name
        }
    }

    private var subtitle: String {
        switch result {
        case .movie(let movie):
            return movie.genre ?? movie.releaseDate ?? ""
        case .series(let series):
            return series.genre ?? series.releaseDate ?? ""
        case .liveStream:
            return "Live"
        }
    }

    private var categoryName: String {
        switch result {
        case .movie:
            return "Movie"
        case .series:
            return "Series"
        case .liveStream:
            return "Live TV"
        }
    }

    private var categoryIcon: String {
        switch result {
        case .movie:
            return "film"
        case .series:
            return "tv"
        case .liveStream:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private var iconName: String {
        switch result {
        case .movie:
            return "film"
        case .series:
            return "tv"
        case .liveStream:
            return "antenna.radiowaves.left.and.right"
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
