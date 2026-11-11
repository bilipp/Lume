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

    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.catalogScope) var catalogScope
    @Environment(\.contentRestriction) var contentRestriction
    @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
    private var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault
    #if os(macOS)
        @Environment(\.openWindow) var openWindow
    #endif
    @Query var playlists: [Playlist]

    @State var selectedSeason: Int = 1
    /// The series' distinct season numbers, cached so the body (season menu,
    /// metadata) doesn't rebuild a Set over every episode on each render — a real
    /// cost for long-running shows with hundreds of episodes. Recomputed when the
    /// episodes relationship changes (see `recomputeSeasons`).
    @State var availableSeasons: [Int] = []
    /// Per-season episode lists, cached alongside `availableSeasons` so the body
    /// doesn't re-filter and re-sort the whole episodes relationship on every
    /// render (it's read by the episode list, the play button and `playTitle`).
    @State var episodesBySeason: [Int: [Episode]] = [:]
    /// The series row whose episodes are being fetched.
    @State private var loadingSeriesID: String?
    @State var playingMedia: PlayableMedia?
    /// A pick made in the source sheet, played once the sheet has gone.
    @State var pendingPick: VODSourceOption?
    @State var sourcePicker: ContentSourcePickerRequest?
    @State var sourceOptions: [VODSourceOption] = []
    /// Copies that failed on every engine since the screen opened.
    @State var failedSourceIDs: Set<String> = []
    /// The copy of the title whose seasons and episodes the screen shows and
    /// plays; nil until the sources are resolved.
    @State var activeSeries: Series?
    /// Favorite and last-watched copy across every copy of the title.
    @State var groupStates: [String: TitleGroupState] = [:]
    @State private var similar: [HomeMediaItem] = []
    @State private var refreshToken: UUID = .init()
    @State private var isLoadingTMDB: Bool
    #if !os(tvOS)
        @State var downloads = DownloadManager.shared
    #endif

    init(series: Series, animationNamespace: Namespace.ID? = nil) {
        self.series = series
        self.animationNamespace = animationNamespace
        let needsFetch = if series.titleTMDBId != nil, TMDBClient.shared.isConfigured {
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
                    resolveSources()
                    refreshGroupState()
                    activeSeries = initialSource()
                    await loadEpisodesIfNeeded()
                    await enrichIfNeeded()
                    await enrichSeriesRatingsIfNeeded(series, context: modelContext)
                    resolveSimilar()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isLoadingTMDB = false
                    }
                }
                // Separate task so a stale-cache refresh runs alongside the
                // enrichment chain above instead of delaying the first paint,
                // and still gets cancelled when the screen goes away.
                .task(id: activeSeries?.id) { await refreshEpisodesIfStale() }
                .onChange(of: series.similarTMDBIds) { resolveSimilar() }
                .onChange(of: refreshToken) { resolveSimilar() }
                .onChange(of: shown.episodes.count) { recomputeSeasons() }
                .onChange(of: playingMedia == nil) { _, isNil in
                    if isNil { refreshGroupState() }
                }
                .onChange(of: sourcesKey) { resolveSources() }
                .contentSourcePicker($sourcePicker, onDismiss: playPendingPick) { pendingPick = $0 }
            #if os(iOS)
                .fullScreenCover(item: $playingMedia, onDismiss: takeSourceFailure) { media in
                    FullScreenPlayerView(media: media)
                }
            #elseif os(macOS)
                .onChange(of: VODSourceFailureHandoff.shared.pending?.id) { takeSourceFailure() }
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

                    if !series.externalRatings.isEmpty {
                        ExternalRatingsView(ratings: series.externalRatings)
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

            if shown.episodes.isEmpty {
                episodesPlaceholder
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(seasonEpisodes) { episode in
                        #if os(tvOS)
                            EpisodeCard(
                                episode: episode,
                                onPlay: { playEpisode(episode) },
                                onToggleWatched: { toggleWatched(episode) },
                                onMarkPreviousWatched: { markPreviousWatched(episode) },
                                onMarkFollowingUnwatched: { markFollowingUnwatched(episode) }
                            )
                        #else
                            DownloadableEpisodeCard(
                                episode: episode,
                                playlist: seriesPlaylist,
                                onPlay: { playEpisode(episode) },
                                onToggleWatched: { toggleWatched(episode) },
                                onMarkPreviousWatched: { markPreviousWatched(episode) },
                                onMarkFollowingUnwatched: { markFollowingUnwatched(episode) }
                            )
                        #endif
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
        if loadingSeriesID == shown.id {
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
                GlassIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(
                    systemImage: groupState.isFavorite ? "heart.fill" : "heart",
                    accessibilityLabel: groupState.isFavorite ? "Remove from favorites" : "Add to favorites"
                ) { toggleFavorite() }
            }
        #else
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: groupState.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(groupState.isFavorite ? .red : .primary)
                        .symbolReplaceTransition(value: groupState.isFavorite)
                }
                .help(groupState.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        #endif
    }

    // MARK: - Derived data

    private var metadata: DetailMetadata {
        let ratingValue = series.rating.flatMap(Double.init)
        return DetailMetadata(
            genre: series.genre,
            year: DetailFormat.year(releaseDate: series.releaseDate, name: series.name),
            duration: nil,
            seasonInfo: availableSeasons.isEmpty ? nil : seasonCountLabel,
            rating: (ratingValue ?? 0) > 0 ? ratingValue : nil,
            contentRating: series.contentRating
        )
    }

    func recomputeSeasons() {
        availableSeasons = Set(shown.episodes.map(\.seasonNum)).sorted()
        episodesBySeason = Dictionary(grouping: shown.episodes, by: \.seasonNum)
            .mapValues { $0.sorted { $0.episodeNum < $1.episodeNum } }
    }

    func determineDefaultSeason() -> Int {
        let seasons = availableSeasons
        guard !seasons.isEmpty else { return 1 }

        // Open on the season of the furthest point reached in the series, so
        // progress in a later season always wins over progress in an earlier
        // one — regardless of which was watched more recently.
        let markers = SeriesEpisodeProgress.markers(in: shown.episodes)
        let target = markers.furthestInProgress ?? markers.furthestAnyProgress
        if let target, seasons.contains(target.seasonNum) {
            return target.seasonNum
        }

        return seasons.first ?? 1
    }

    private var seasonEpisodes: [Episode] {
        episodesBySeason[selectedSeason] ?? []
    }

    /// Play button target — see `SeriesEpisodeProgress.nextEpisode`. Read on
    /// every body evaluation, so it must stay O(episodes) with no sorting.
    var nextEpisode: Episode? {
        SeriesEpisodeProgress.nextEpisode(in: shown.episodes, fallback: seasonEpisodes.first)
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

    /// The playlist that owns the copy on screen, which plays its episodes.
    var seriesPlaylist: Playlist? {
        playlists.owner(ofContentID: shown.id)
    }

    // MARK: - Loading & enrichment

    func loadEpisodesIfNeeded() async {
        if shown.episodes.isEmpty {
            await loadEpisodes()
        }
        recomputeSeasons()
        selectedSeason = determineDefaultSeason()
    }

    /// Re-pulls a cached episode list once the playlist has synced past it. The
    /// cached episodes stay on screen while it runs and new ones merge in, so
    /// this is silent unless something actually changed. The empty case is the
    /// blocking `loadEpisodesIfNeeded` path's job.
    ///
    /// m3u and WebDAV are skipped: they import and prune episodes alongside the
    /// rest of the catalog on every sync, so there is nothing to pull
    /// per-series there.
    private func refreshEpisodesIfStale() async {
        guard let active = activeSeries,
              !active.episodes.isEmpty,
              let playlist = playlists.owner(ofContentID: active.id),
              playlist.supportsPerSeriesEpisodeFetch,
              active.episodesAreStale(lastSyncedAt: playlist.lastSyncDate)
        else { return }
        await loadEpisodes()
    }

    private func loadEpisodes() async {
        let target = shown
        guard let playlist = playlists.owner(ofContentID: target.id), loadingSeriesID != target.id else { return }
        loadingSeriesID = target.id
        defer {
            if loadingSeriesID == target.id { loadingSeriesID = nil }
        }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        // A failed fetch must not reach `insertEpisodes`: it stamps the episode
        // cache, which would call the list fresh until the staleness window
        // reopens — the exact thing keeping a device an episode behind.
        guard let parsed = try? await manager.fetchEpisodes(
            seriesId: target.seriesId,
            seriesElementId: target.id,
            playlist: playlist
        ) else { return }
        // Insert through the view's own context, attaching to `target`, so its
        // episodes relationship — and this view — update synchronously.
        await MainActor.run { target.insertEpisodes(parsed, into: modelContext) }
    }

    private func enrichIfNeeded() async {
        guard let tmdbId = series.titleTMDBId else { return }
        if let enrichedAt = series.tmdbEnrichedAt,
           Date().timeIntervalSince(enrichedAt) < 14 * 24 * 3600
        {
            return
        }
        // Fetch off-thread, then apply on the view's own context. Using the
        // background enrichSeries() path deletes-and-reinserts CastMember rows
        // from a separate ModelContext; if the main context holds faulted
        // references to those objects and a render fires before the merge lands,
        // SwiftData fires a fault against a deleted store row → _assertionFailure.
        guard await enrichSeriesDetails(series, tmdbId: tmdbId, context: modelContext) else { return }
        refreshToken = UUID()
    }
}

// MARK: - Related titles

private extension SeriesDetailView {
    func resolveSimilar() {
        let ids = series.similarTitleIds
        guard !ids.isEmpty else { similar = []; return }

        let ranking = TitleGrouping.Ranking(scope: catalogScope)

        var resolved: [HomeMediaItem] = []
        for tmdbId in ids {
            let seriesMatches = (try? modelContext.fetch(
                FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = TitleGrouping.railRow(seriesMatches, excluding: series, tab: .series, ranking: ranking, grouped: groupDuplicateTitles) {
                resolved.append(.series(match))
                continue
            }
            let movieMatches = (try? modelContext.fetch(
                FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
            )) ?? []
            if let match = TitleGrouping.railRow(movieMatches, excluding: series, tab: .movies, ranking: ranking, grouped: groupDuplicateTitles) {
                resolved.append(.movie(match))
            }
        }
        similar = Array(resolved.prefix(12))
    }
}

// MARK: - Actions

private extension SeriesDetailView {
    func toggleWatched(_ episode: Episode) {
        episode.setWatched(!episode.isWatched)
        WatchedTrackers.sync(episode: episode, watched: episode.isWatched)
        #if !os(tvOS)
            if episode.isWatched {
                downloads.checkAutoDelete(id: episode.id)
            }
        #endif
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

// MARK: - Derived helpers

extension SeriesDetailView {
    private var seasonCountLabel: String {
        availableSeasons.count == 1 ? String(localized: "1 Season") : String(localized: "\(availableSeasons.count) Seasons")
    }

    var playTitle: LocalizedStringKey {
        guard let episode = nextEpisode else { return "Play" }
        let resume = !episode.isWatched && episode.watchProgress > 1
        return resume ? "Resume S\(episode.seasonNum) E\(episode.episodeNum)" : "Play S\(episode.seasonNum) E\(episode.episodeNum)"
    }
}
