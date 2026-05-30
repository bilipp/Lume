//
//  SeriesDetailView.swift
//  Lume
//
//  Apple TV-style series detail screen. Shares the hero / metadata / cast /
//  similar layout with MovieDetailView, adding a season picker and redesigned
//  episode cards. TMDB enrichment and episodes are loaded lazily on appear.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct SeriesDetailView: View {
    let series: Series

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]

    @State private var selectedSeason: Int = 1
    @State private var isLoadingEpisodes = false
    @State private var playingMedia: PlayableMedia?
    @State private var similar: [HomeMediaItem] = []

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DetailMetrics.sectionSpacing) {
                    DetailHero(
                        title: series.name,
                        backdropURL: TMDBClient.backdropURL(series.backdropPath),
                        posterFallbackURL: URL(string: series.cover ?? ""),
                        tagline: series.tagline,
                        metadata: metadata,
                        height: DetailMetrics.heroHeight(for: proxy.size),
                        fallbackSymbol: "tv"
                    )

                    actions
                        .padding(.horizontal, DetailMetrics.contentPadding)

                    if let plot = series.plot, !plot.isEmpty {
                        ExpandableText(text: plot)
                            .padding(.horizontal, DetailMetrics.contentPadding)
                    }

                    episodesSection

                    if !series.orderedCast.isEmpty {
                        section(title: "Cast") {
                            CastRow(cast: series.orderedCast)
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
        .task(id: series.id) {
            await loadEpisodesIfNeeded()
            await enrichIfNeeded()
            resolveSimilar()
        }
        .onChange(of: series.similarTMDBIds) { resolveSimilar() }
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
            title: playTitle,
            isEnabled: nextEpisode != nil && seriesPlaylist != nil,
            action: { if let episode = nextEpisode { playEpisode(episode) } }
        )
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DetailSectionHeader(title: "Episodes")
                Spacer()
                if availableSeasons.count > 1 {
                    seasonMenu
                }
            }
            .padding(.horizontal, DetailMetrics.contentPadding)

            if series.episodes.isEmpty {
                episodesPlaceholder
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(seasonEpisodes) { episode in
                        EpisodeCard(episode: episode) { playEpisode(episode) }
                    }
                }
                .padding(.horizontal, DetailMetrics.contentPadding)
            }
        }
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(availableSeasons, id: \.self) { season in
                Button {
                    selectedSeason = season
                } label: {
                    if season == selectedSeason {
                        Label("Season \(season)", systemImage: "checkmark")
                    } else {
                        Text("Season \(season)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Season \(selectedSeason)")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var episodesPlaceholder: some View {
        if isLoadingEpisodes {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading episodes…").foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 12) {
                Text("No episodes available").foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await loadEpisodes() }
                }
                .buttonStyle(.bordered)
            }
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
        if let director = series.director, !director.isEmpty {
            rows.append(("Director", director))
        }
        if let genre = series.genre, !genre.isEmpty {
            rows.append(("Genre", genre))
        }
        if let cast = series.cast, !cast.isEmpty, series.orderedCast.isEmpty {
            rows.append(("Cast", cast))
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
            GlassIconButton(
                systemImage: series.isFavorite ? "heart.fill" : "heart",
                accessibilityLabel: series.isFavorite ? "Remove from favorites" : "Add to favorites"
            ) { toggleFavorite() }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: series.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(series.isFavorite ? .red : .primary)
            }
            .help(series.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        #endif
    }

    // MARK: - Derived data

    private var metadata: DetailMetadata {
        let ratingValue = series.rating.flatMap(Double.init)
        return DetailMetadata(
            genre: series.genre,
            year: DetailFormat.year(from: series.releaseDate),
            duration: nil,
            seasonInfo: availableSeasons.isEmpty ? nil : seasonCountLabel,
            rating: (ratingValue ?? 0) > 0 ? ratingValue : nil,
            contentRating: series.contentRating
        )
    }

    private var seasonCountLabel: String {
        availableSeasons.count == 1 ? "1 Season" : "\(availableSeasons.count) Seasons"
    }

    private var availableSeasons: [Int] {
        Set(series.episodes.map(\.seasonNum)).sorted()
    }

    private var seasonEpisodes: [Episode] {
        series.episodes
            .filter { $0.seasonNum == selectedSeason }
            .sorted { $0.episodeNum < $1.episodeNum }
    }

    /// The episode the Play button starts: the earliest partially-watched
    /// episode, otherwise the first episode of the selected season.
    private var nextEpisode: Episode? {
        let inProgress = series.episodes
            .filter { $0.watchProgress > 1 && !$0.isWatched }
            .sorted { ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum) }
            .first
        return inProgress ?? seasonEpisodes.first ?? series.episodes.sorted {
            ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum)
        }.first
    }

    private var playTitle: String {
        guard let episode = nextEpisode else { return "Play" }
        let prefix = (episode.watchProgress > 1) ? "Resume" : "Play"
        return "\(prefix) S\(episode.seasonNum) E\(episode.episodeNum)"
    }

    private var backgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private var seriesPlaylist: Playlist? {
        playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }

    // MARK: - Loading & enrichment

    private func loadEpisodesIfNeeded() async {
        if series.episodes.isEmpty {
            await loadEpisodes()
        }
        if !availableSeasons.contains(selectedSeason), let first = availableSeasons.first {
            selectedSeason = first
        }
    }

    private func loadEpisodes() async {
        guard let playlist = seriesPlaylist, !isLoadingEpisodes else { return }
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        try? await manager.syncEpisodes(for: series, playlist: playlist)
        if !availableSeasons.contains(selectedSeason), let first = availableSeasons.first {
            selectedSeason = first
        }
    }

    private func enrichIfNeeded() async {
        guard let tmdbId = series.tmdbId else { return }
        if let enrichedAt = series.tmdbEnrichedAt,
           Date().timeIntervalSince(enrichedAt) < 14 * 24 * 3600 {
            return
        }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        try? await manager.enrichSeries(id: series.id, tmdbId: tmdbId)
    }

    private func resolveSimilar() {
        let ids = series.similarTMDBIds
        guard !ids.isEmpty else { similar = []; return }

        let playlistPrefix = series.id.components(separatedBy: "-series-").first
        func owned(_ id: String) -> Bool {
            guard let prefix = playlistPrefix else { return true }
            return id.hasPrefix(prefix)
        }

        var resolved: [HomeMediaItem] = []
        for tmdbId in ids {
            let seriesMatches = (try? modelContext.fetch(
                FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = seriesMatches.first(where: { owned($0.id) && $0.id != series.id }) {
                resolved.append(.series(match))
                continue
            }
            let movieMatches = (try? modelContext.fetch(
                FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = movieMatches.first(where: { owned($0.id) }) {
                resolved.append(.movie(match))
            }
        }
        similar = Array(resolved.prefix(12))
    }

    // MARK: - Actions

    private func playEpisode(_ episode: Episode) {
        guard let playlist = seriesPlaylist,
              let media = PlayableMedia.from(episode: episode, playlist: playlist) else { return }
        #if os(macOS)
        openWindow(id: "player", value: media)
        #else
        playingMedia = media
        #endif
    }

    private func toggleFavorite() {
        series.isFavorite.toggle()
        series.addedToWatchlistDate = series.isFavorite ? Date() : nil
    }
}

// MARK: - Episode card

/// A wide episode row: 16:9 still on the left, title / runtime / synopsis on the
/// right, a resume progress bar and a play affordance.
private struct EpisodeCard: View {
    let episode: Episode
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 14) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text("E\(episode.episodeNum)" + (episode.title.isEmpty ? "" : " · \(episode.title)"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let minutes = DetailFormat.minutes(episode.durationSecs) {
                        Text(minutes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let plot = episode.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let progress = resumeFraction {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var thumbnail: some View {
        ZStack {
            AsyncImage(url: URL(string: episode.movieImage ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty where episode.movieImage != nil:
                    Rectangle().fill(Color.gray.opacity(0.25)).overlay { ProgressView() }
                default:
                    Rectangle().fill(Color.gray.opacity(0.25))
                        .overlay {
                            Text("E\(episode.episodeNum)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 142, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .opacity(0.9)
        }
    }

    private var resumeFraction: Double? {
        guard episode.watchProgress > 0,
              let duration = episode.durationSecs, duration > 0,
              !episode.isWatched else { return nil }
        return min(episode.watchProgress / Double(duration), 1)
    }
}

#Preview {
    NavigationStack {
        SeriesDetailView(
            series: Series(
                id: "preview",
                seriesId: 1,
                name: "Sample Series"
            )
        )
    }
    .modelContainer(for: Playlist.self, inMemory: true)
}
