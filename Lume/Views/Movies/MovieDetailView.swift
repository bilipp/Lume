//
//  MovieDetailView.swift
//  Lume
//
//  Apple TV-style movie detail screen: a full-bleed backdrop hero, a metadata
//  line, a prominent Play button, secondary actions, an expandable synopsis,
//  a cast row with photos and a "You May Also Like" strip. TMDB enrichment is
//  fetched lazily on appear and persisted, so revisits are instant.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct MovieDetailView: View {
    let movie: Movie

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @State private var playingMedia: PlayableMedia?
    @State private var similar: [HomeMediaItem] = []
    @State private var refreshToken: UUID = UUID()

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DetailMetrics.sectionSpacing) {
                    DetailHero(
                        title: movie.name,
                        backdropURL: TMDBClient.backdropURL(movie.backdropPath),
                        posterFallbackURL: URL(string: movie.streamIcon ?? ""),
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

                    information
                        .padding(.horizontal, DetailMetrics.contentPadding)

                    if !similar.isEmpty {
                        section(title: "You May Also Like") {
                            SimilarRow(items: similar)
                        }
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
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
            resolveSimilar()
        }
        .onChange(of: movie.similarTMDBIds) { resolveSimilar() }
        .onChange(of: refreshToken) { resolveSimilar() }
        #if os(iOS)
        .fullScreenCover(item: $playingMedia) { media in
            FullScreenPlayerView(media: media)
        }
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title: title)
                .padding(.horizontal, DetailMetrics.contentPadding)
            content()
        }
    }

    private var actions: some View {
        PrimaryPlayButton(
            title: movie.watchProgress > 1 ? "Resume" : "Play",
            isEnabled: moviePlaylist != nil,
            action: startPlayback
        )
    }

    @ViewBuilder
    private var information: some View {
        let rows = informationRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DetailSectionHeader(title: "Information")
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
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
        // Skip if enriched recently; backdrop/cast/similar rarely change.
        if let enrichedAt = movie.tmdbEnrichedAt,
           Date().timeIntervalSince(enrichedAt) < 14 * 24 * 3600 {
            return
        }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        try? await manager.enrichMovie(id: movie.id, tmdbId: tmdbId)
        // Force the view's context to pick up TMDB enrichment data written
        // on the background context (backdrop, cast, tagline, etc.).
        await MainActor.run {
            modelContext.processPendingChanges()
            refreshToken = UUID()
        }
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
        }
    }
}

#Preview {
    NavigationStack {
        MovieDetailView(
            movie: Movie(
                id: "preview",
                streamId: 1,
                name: "Sample Movie"
            )
        )
    }
    .modelContainer(for: Playlist.self, inMemory: true)
}
