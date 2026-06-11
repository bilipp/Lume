//
//  MovieDetailView.swift
//  Lume
//
//  Apple TV-style movie detail screen: a full-bleed backdrop hero, a metadata
//  line, a prominent Play button, secondary actions, an expandable synopsis,
//  a cast row with photos and a "You May Also Like" strip. TMDB enrichment is
//  fetched lazily on appear and persisted, so revisits are instant.
//

import SwiftData
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

struct MovieDetailView: View {
    let movie: Movie
    var animationNamespace: Namespace.ID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @State private var playingMedia: PlayableMedia?
    @State private var similar: [HomeMediaItem] = []
    @State private var collectionMovies: [HomeMediaItem] = []
    @State private var otherSources: [HomeMediaItem] = []
    @State private var refreshToken: UUID = .init()
    @State private var isLoadingTMDB: Bool
    #if !os(tvOS)
        @State private var downloads = DownloadManager.shared
        @AppStorage(DownloadManager.maxConcurrentKey) private var maxConcurrent = 1
        @AppStorage(DownloadManager.autoDeleteKey) private var autoDeleteAfterWatching = false
    #endif

    init(movie: Movie, animationNamespace: Namespace.ID? = nil) {
        self.movie = movie
        self.animationNamespace = animationNamespace
        let needsFetch = if movie.tmdbId != nil, TMDBClient.shared.isConfigured {
            if let enrichedAt = movie.tmdbEnrichedAt,
               Date().timeIntervalSince(enrichedAt) < 14 * 24 * 3600
            {
                false
            } else {
                true
            }
        } else {
            false
        }
        _isLoadingTMDB = State(initialValue: needsFetch)
    }

    var body: some View {
        #if os(tvOS)
            TVMovieDetailView(movie: movie)
        #else
            Group {
                if isLoadingTMDB {
                    loadingView
                        .transition(.opacity)
                } else {
                    detailView
                        .transition(.opacity)
                }
            }
            .background(backgroundColor)
            #if os(iOS)
                .toolbar(.hidden, for: .tabBar)
                .navigationBarBackButtonHidden(true)
                .toolbarBackground(.hidden, for: .navigationBar)
            #endif
                .toolbar { toolbarContent }
                .task(id: movie.id) {
                    await enrichIfNeeded()
                    await enrichMovieRatingsIfNeeded(movie, context: modelContext)
                    resolveSimilar()
                    await resolveCollection()
                    resolveOtherSources()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isLoadingTMDB = false
                    }
                }
                .onChange(of: movie.similarTMDBIds) { resolveSimilar() }
                .onChange(of: movie.collectionId) { Task { await resolveCollection() } }
                .onChange(of: refreshToken) { resolveSimilar() }
            #if os(iOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
        #endif
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text(movie.name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Loading details…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private var detailView: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DetailMetrics.sectionSpacing) {
                    DetailHero(
                        title: movie.name,
                        backdropURL: TMDBClient.backdropURL(movie.backdropPath),
                        posterFallbackURL: URL(string: movie.streamIcon ?? ""),
                        logoURL: TMDBClient.logoURL(movie.logoPath),
                        tagline: movie.tagline,
                        metadata: metadata,
                        height: DetailMetrics.heroHeight(for: proxy.size),
                        fallbackSymbol: "film"
                    )

                    actions
                        .padding(.horizontal, DetailMetrics.contentPadding)

                    if let plot = movie.plot, !plot.isEmpty {
                        ExpandableText(text: plot)
                            .padding(.horizontal, DetailMetrics.contentPadding)
                    }

                    if !movie.externalRatings.isEmpty {
                        ExternalRatingsView(ratings: movie.externalRatings)
                            .padding(.horizontal, DetailMetrics.contentPadding)
                    }

                    if let trailer = movie.youtubeTrailer, !trailer.isEmpty {
                        Button {
                            openTrailer(trailer)
                        } label: {
                            Label("Watch Trailer", systemImage: "play.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, DetailMetrics.contentPadding)
                    }

                    if !movie.orderedCast.isEmpty {
                        section(title: "Cast") {
                            CastRow(cast: movie.orderedCast)
                        }
                    }

                    if !movie.trailers.isEmpty {
                        section(title: "Videos") {
                            VideoRow(videos: movie.trailers) { video in
                                openVideo(video)
                            }
                        }
                    }

                    information
                        .padding(.horizontal, DetailMetrics.contentPadding)

                    if !similar.isEmpty {
                        section(title: "You May Also Like") {
                            SimilarRow(items: similar, animationNamespace: animationNamespace)
                        }
                    }

                    if !collectionMovies.isEmpty, let name = movie.collectionName {
                        section(title: "Part of \(name)") {
                            SimilarRow(items: collectionMovies, animationNamespace: animationNamespace)
                        }
                    }

                    if !otherSources.isEmpty {
                        section(title: "Other Sources") {
                            SimilarRow(items: otherSources, animationNamespace: animationNamespace)
                        }
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Sections

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title: title)
                .padding(.horizontal, DetailMetrics.contentPadding)
            content()
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            PrimaryPlayButton(
                title: movie.watchProgress > 1 ? "Resume" : "Play",
                isEnabled: moviePlaylist != nil,
                action: startPlayback
            )
            #if !os(tvOS)
                if let playlist = moviePlaylist {
                    DownloadButton(
                        id: movie.id,
                        downloadStatus: movie.downloadStatus,
                        downloads: downloads,
                        onStart: { downloads.startDownload(movie: movie, playlist: playlist) },
                        onDelete: { deleteMovieDownload() }
                    )
                }
            #endif
        }
    }

    @ViewBuilder
    private var information: some View {
        let rows = informationRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DetailSectionHeader(title: "Information")
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(row.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.callout)
                    }
                }
            }
        }
    }

    private var informationRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        rows.append(("Title", movie.name))
        if let director = movie.director, !director.isEmpty {
            rows.append(("Director", director))
        }
        if let genre = movie.genre, !genre.isEmpty {
            rows.append(("Genre", genre))
        }
        if let actors = movie.actors, !actors.isEmpty, movie.orderedCast.isEmpty {
            rows.append(("Cast", actors))
        }
        return rows
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                GlassIconButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    GlassIconButton(
                        systemImage: movie.isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                        accessibilityLabel: movie.isWatched ? "Mark as unwatched" : "Mark as watched"
                    ) { toggleWatched() }

                    GlassIconButton(
                        systemImage: movie.isFavorite ? "heart.fill" : "heart",
                        accessibilityLabel: movie.isFavorite ? "Remove from favorites" : "Add to favorites"
                    ) { toggleFavorite() }
                }
            }
        #else
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleWatched()
                } label: {
                    Image(systemName: movie.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(movie.isWatched ? "Mark as Unwatched" : "Mark as Watched")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: movie.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(movie.isFavorite ? .red : .primary)
                }
                .help(movie.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        #endif
    }

    // MARK: - Derived data

    private var metadata: DetailMetadata {
        DetailMetadata(
            genre: movie.genre,
            year: DetailFormat.year(from: movie.releaseDate),
            duration: DetailFormat.duration(movie.durationSecs),
            seasonInfo: nil,
            rating: movie.rating > 0 ? movie.rating : nil,
            contentRating: movie.contentRating
        )
    }

    private var backgroundColor: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
            Color.black
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    /// The playlist this movie actually belongs to (ids are `"<playlistUUID>-…"`),
    /// so playback uses the correct credentials. Falls back to the first.
    private var moviePlaylist: Playlist? {
        playlists.first { movie.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }

    // MARK: - Enrichment

    private func enrichIfNeeded() async {
        guard let tmdbId = movie.tmdbId else { return }
        if let enrichedAt = movie.tmdbEnrichedAt,
           Date().timeIntervalSince(enrichedAt) < 14 * 24 * 3600
        {
            return
        }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        guard let details = try? await manager.fetchTMDBMovieDetails(tmdbId: tmdbId) else { return }
        applyMovieDetails(details, to: movie, context: modelContext)
        try? modelContext.save()
        refreshToken = UUID()
    }

    private func resolveSimilar() {
        let ids = movie.similarTMDBIds
        guard !ids.isEmpty else { similar = []; return }

        // Scope to the same playlist this movie belongs to.
        let playlistPrefix = movie.id.components(separatedBy: "-movie-").first
        func owned(_ id: String) -> Bool {
            guard let prefix = playlistPrefix else { return true }
            return id.hasPrefix(prefix)
        }

        var resolved: [HomeMediaItem] = []
        for tmdbId in ids {
            let movieMatches = (try? modelContext.fetch(
                FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = movieMatches.first(where: { owned($0.id) && $0.id != movie.id }) {
                resolved.append(.movie(match))
                continue
            }
            let seriesMatches = (try? modelContext.fetch(
                FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = seriesMatches.first(where: { owned($0.id) }) {
                resolved.append(.series(match))
            }
        }
        similar = Array(resolved.prefix(12))
    }

    private func resolveCollection() async {
        guard let collectionId = movie.collectionId else {
            collectionMovies = []
            return
        }

        let manager = ContentSyncManager(modelContainer: modelContext.container)
        let partIDs: [Int]
        do {
            partIDs = try await manager.fetchTMDBCollectionMovieIDs(collectionId: collectionId)
        } catch {
            collectionMovies = []
            return
        }

        let playlistPrefix = movie.id.components(separatedBy: "-movie-").first
        func owned(_ id: String) -> Bool {
            guard let prefix = playlistPrefix else { return true }
            return id.hasPrefix(prefix)
        }

        var resolved: [HomeMediaItem] = []
        for tmdbId in partIDs {
            let movieMatches = (try? modelContext.fetch(
                FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = movieMatches.first(where: { owned($0.id) && $0.id != movie.id }) {
                resolved.append(.movie(match))
            }
        }
        collectionMovies = resolved
    }

    private func resolveOtherSources() {
        otherSources = OtherSources.resolve(for: movie, in: modelContext)
    }

    // MARK: - Actions

    private func startPlayback() {
        guard let playlist = moviePlaylist,
              let media = PlayableMedia.from(movie: movie, playlist: playlist) else { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }

    private func openTrailer(_ trailer: String) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(trailer)") else { return }
        #if os(iOS)
            UIApplication.shared.open(url)
        #elseif os(macOS)
            NSWorkspace.shared.open(url)
        #endif
    }

    private func toggleFavorite() {
        movie.isFavorite.toggle()
        movie.addedToWatchlistDate = movie.isFavorite ? Date() : nil
    }

    private func toggleWatched() {
        movie.isWatched.toggle()
        if movie.isWatched {
            movie.watchProgress = Double(movie.durationSecs ?? 0)
            #if !os(tvOS)
                downloads.checkAutoDelete(id: movie.id)
            #endif
        }
        TraktService.shared.syncWatched(movie: movie, watched: movie.isWatched)
    }

    #if !os(tvOS)
        private func deleteMovieDownload() {
            downloads.deleteLocalFile(id: movie.id)
        }
    #endif
}

#Preview("Basic") {
    let container = previewContainer()
    let movie = PreviewData.sampleMovie
    return NavigationStack {
        MovieDetailView(movie: movie)
    }
    .modelContainer(container)
}

#Preview("With TMDB") {
    let container = previewContainer()
    let movie = PreviewData.sampleMovie
    movie.plot = "A computer hacker learns about the true nature of reality."
    movie.genre = "Action, Sci-Fi"
    movie.releaseDate = "1999-03-31"
    movie.durationSecs = 8160
    movie.director = "Lana Wachowski, Lilly Wachowski"
    movie.actors = "Keanu Reeves, Laurence Fishburne, Carrie-Anne Moss"
    movie.youtubeTrailer = "d6j_wN1QO7s"
    movie.backdropPath = "/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"
    movie.tagline = "Welcome to the Real World."
    movie.contentRating = "R"
    movie.tmdbId = 603
    movie.tmdb = "603"
    movie.tmdbEnrichedAt = Date().addingTimeInterval(-3600)
    movie.isFavorite = true
    return NavigationStack {
        MovieDetailView(movie: movie)
    }
    .modelContainer(container)
}

#Preview("Watched") {
    let container = previewContainer()
    let movie = PreviewData.sampleMovie
    movie.name = "Inception"
    movie.streamId = 2
    movie.plot = "A thief who steals corporate secrets through dream-sharing technology."
    movie.genre = "Action, Sci-Fi, Thriller"
    movie.releaseDate = "2010-07-16"
    movie.durationSecs = 8880
    movie.director = "Christopher Nolan"
    movie.actors = "Leonardo DiCaprio, Joseph Gordon-Levitt, Elliot Page"
    movie.isWatched = true
    movie.watchProgress = 8880
    return NavigationStack {
        MovieDetailView(movie: movie)
    }
    .modelContainer(container)
}

#Preview("No TMDB") {
    let container = previewContainer()
    let movie = PreviewData.sampleMovie
    movie.plot = nil
    movie.director = nil
    movie.actors = nil
    movie.genre = nil
    return NavigationStack {
        MovieDetailView(movie: movie)
    }
    .modelContainer(container)
}

#Preview("Favorite") {
    let container = previewContainer()
    let movie = PreviewData.sampleMovie
    movie.isFavorite = true
    movie.backdropPath = "/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"
    movie.tagline = "Welcome to the Real World."
    movie.tmdbId = 603
    return NavigationStack {
        MovieDetailView(movie: movie)
    }
    .modelContainer(container)
}
