//
//  SeriesDetailView.swift
//  Lume
//
//  Apple TV-style series detail screen. Shares the hero / metadata / cast /
//  similar layout with MovieDetailView, adding a season picker and redesigned
//  episode cards. TMDB enrichment and episodes are loaded lazily on appear.
//

import SwiftData
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

struct SeriesDetailView: View {
    let series: Series
    var animationNamespace: Namespace.ID?

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
    @State private var refreshToken: UUID = .init()
    @State private var isLoadingTMDB: Bool

    init(series: Series, animationNamespace: Namespace.ID? = nil) {
        self.series = series
        self.animationNamespace = animationNamespace
        let needsFetch = if series.tmdbId != nil, TMDBClient.shared.isConfigured {
            if let enrichedAt = series.tmdbEnrichedAt,
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
            TVSeriesDetailView(series: series)
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
                .task(id: series.id) {
                    await loadEpisodesIfNeeded()
                    await enrichIfNeeded()
                    resolveSimilar()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isLoadingTMDB = false
                    }
                }
                .onChange(of: series.similarTMDBIds) { resolveSimilar() }
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

            Text(series.name)
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
                        title: series.name,
                        backdropURL: TMDBClient.backdropURL(series.backdropPath),
                        posterFallbackURL: URL(string: series.cover ?? ""),
                        logoURL: TMDBClient.logoURL(series.logoPath),
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

                    if !series.trailers.isEmpty {
                        section(title: "Videos") {
                            VideoRow(videos: series.trailers) { video in
                                if let url = video.youtubeURL { openVideoURL(url) }
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
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Sections

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
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
                        EpisodeCard(
                            episode: episode,
                            onPlay: { playEpisode(episode) },
                            onToggleWatched: { toggleWatched(episode) },
                            onMarkPreviousWatched: { markPreviousWatched(episode) },
                            onMarkFollowingUnwatched: { markFollowingUnwatched(episode) }
                        )
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
        rows.append(("Title", series.name))
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

    private func determineDefaultSeason() -> Int {
        let seasons = availableSeasons
        guard !seasons.isEmpty else { return 1 }

        // Open on the season of the furthest point reached in the series, so
        // progress in a later season always wins over progress in an earlier
        // one — regardless of which was watched more recently.
        let target = furthestInProgressEpisode ?? furthestProgressEpisode
        if let target, seasons.contains(target.seasonNum) {
            return target.seasonNum
        }

        return seasons.first ?? 1
    }

    private var seasonEpisodes: [Episode] {
        series.episodes
            .filter { $0.seasonNum == selectedSeason }
            .sorted { $0.episodeNum < $1.episodeNum }
    }

    /// The furthest partially-watched (not completed) episode in the series,
    /// ordered by season then episode.
    private var furthestInProgressEpisode: Episode? {
        series.episodes
            .filter { $0.watchProgress > 1 && !$0.isWatched }
            .max { ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum) }
    }

    /// The furthest episode with any watch progress, including completed ones.
    private var furthestProgressEpisode: Episode? {
        series.episodes
            .filter { $0.watchProgress > 0 || $0.isWatched }
            .max { ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum) }
    }

    /// The episode the Play button starts: resume the furthest partially-watched
    /// episode, otherwise the first episode of the selected season.
    private var nextEpisode: Episode? {
        furthestInProgressEpisode ?? seasonEpisodes.first ?? series.episodes.sorted {
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
        #elseif os(tvOS)
            Color.black
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
        selectedSeason = determineDefaultSeason()
    }

    private func loadEpisodes() async {
        guard let playlist = seriesPlaylist, !isLoadingEpisodes else { return }
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        try? await manager.syncEpisodes(for: series, playlist: playlist)
        // Force the view's context to pick up the background-context writes
        // so that series.episodes is re-evaluated immediately.
        await MainActor.run {
            modelContext.processPendingChanges()
            refreshToken = UUID()
        }
        selectedSeason = determineDefaultSeason()
    }

    private func enrichIfNeeded() async {
        guard let tmdbId = series.tmdbId else { return }
        if let enrichedAt = series.tmdbEnrichedAt,
           Date().timeIntervalSince(enrichedAt) < 14 * 24 * 3600
        {
            return
        }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        guard let details = try? await manager.fetchTMDBTVDetails(tmdbId: tmdbId) else { return }
        applySeriesDetails(details, to: series, context: modelContext)
        try? modelContext.save()
        refreshToken = UUID()
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
}

// MARK: - Actions

private extension SeriesDetailView {
    func playEpisode(_ episode: Episode) {
        guard let playlist = seriesPlaylist,
              let media = PlayableMedia.from(episode: episode, playlist: playlist) else { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }

    func toggleFavorite() {
        series.isFavorite.toggle()
        series.addedToWatchlistDate = series.isFavorite ? Date() : nil
    }

    func toggleWatched(_ episode: Episode) {
        episode.setWatched(!episode.isWatched)
        try? modelContext.save()
    }

    func markPreviousWatched(_ episode: Episode) {
        episode.markEarlierEpisodesWatched()
        try? modelContext.save()
    }

    func markFollowingUnwatched(_ episode: Episode) {
        episode.markLaterEpisodesUnwatched()
        try? modelContext.save()
    }
}

#Preview("Basic") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("With TMDB + Episodes") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    series.backdropPath = "/abc123backdrop.jpg"
    series.tagline = "I am the one who knocks."
    series.contentRating = "TV-MA"
    series.tmdbId = 1396
    series.tmdb = "1396"
    series.tmdbEnrichedAt = Date().addingTimeInterval(-3600)
    series.isFavorite = true
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("No Episodes") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("No TMDB") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    series.plot = nil
    series.genre = nil
    series.director = nil
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("Favorite") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    series.backdropPath = "/abc123backdrop.jpg"
    series.tagline = "I am the one who knocks."
    series.tmdbId = 1396
    series.isFavorite = true
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}
