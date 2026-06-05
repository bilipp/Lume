//
//  TVSeriesDetailView.swift
//  Lume
//
//  tvOS series detail screen. Shares the hero / about / ratings / cast / related
//  layout with TVMovieDetailView, adding a focusable season selector and a
//  horizontal rail of large episode cards (the prominent scrolled content, per
//  the Figma template). Episodes and TMDB enrichment load lazily on appear.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVSeriesDetailView: View {
        let series: Series

        @Environment(\.modelContext) private var modelContext
        @Query private var playlists: [Playlist]

        @State private var selectedSeason: Int = 1
        @State private var isLoadingEpisodes = false
        @State private var playingMedia: PlayableMedia?
        @State private var similar: [HomeMediaItem] = []
        @State private var otherSources: [HomeMediaItem] = []
        @State private var refreshToken: UUID = .init()
        @State private var isLoadingTMDB: Bool
        @State private var showYouTubeUnavailable = false

        private enum FocusTarget: Hashable { case play }
        @FocusState private var focus: FocusTarget?

        init(series: Series) {
            self.series = series
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
            Group {
                if isLoadingTMDB {
                    TVDetailLoadingView(title: series.name)
                        .transition(.opacity)
                } else {
                    content
                        .transition(.opacity)
                        .onAppear { focus = .play }
                }
            }
            .background(Color.black)
            .ignoresSafeArea()
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            .alert("YouTube Unavailable", isPresented: $showYouTubeUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Install the YouTube app on your Apple TV to watch trailers.")
            }
            .task(id: series.id) {
                await loadEpisodesIfNeeded()
                await enrichIfNeeded()
                resolveSimilar()
                resolveOtherSources()
                withAnimation(.easeInOut(duration: 0.3)) {
                    isLoadingTMDB = false
                }
                // Episodes are now loaded, so the Play button is enabled and can
                // accept focus (an assignment made before this point is ignored
                // by the focus engine while the button is disabled).
                focus = .play
            }
            .onChange(of: series.similarTMDBIds) { resolveSimilar() }
            .onChange(of: refreshToken) { resolveSimilar() }
        }

        private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: TVDetailMetrics.sectionSpacing) {
                    hero

                    episodesSection

                    aboutSection

                    if !series.orderedCast.isEmpty {
                        TVRail(title: "Cast") {
                            ForEach(series.orderedCast) { member in
                                TVCastCard(member: member)
                            }
                        }
                    }

                    if !series.trailers.isEmpty {
                        TVRail(title: "Videos") {
                            ForEach(series.trailers) { video in
                                TVVideoCard(video: video) {
                                    openVideo(video) { showYouTubeUnavailable = true }
                                }
                            }
                        }
                    }

                    if !similar.isEmpty {
                        TVRail(title: "You May Also Like") {
                            ForEach(similar) { item in
                                posterLink(for: item)
                            }
                        }
                    }

                    if !otherSources.isEmpty {
                        TVRail(title: "Other Sources") {
                            ForEach(otherSources) { item in
                                posterLink(for: item)
                            }
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, .play)
        }

        // MARK: - Hero

        private var hero: some View {
            TVDetailHero(
                title: series.name,
                backdropURL: TMDBClient.backdropURL(series.backdropPath),
                posterFallbackURL: URL(string: series.cover ?? ""),
                logoURL: TMDBClient.logoURL(series.logoPath),
                tagline: series.tagline,
                rating: rating5,
                badge: series.contentRating,
                metaItems: heroMetaItems,
                fallbackSymbol: "tv"
            ) {
                TVPlayButton(
                    title: playTitle,
                    isEnabled: nextEpisode != nil && seriesPlaylist != nil,
                    action: { if let episode = nextEpisode { playEpisode(episode) } }
                )
                .focused($focus, equals: .play)

                HStack(spacing: 18) {
                    TVSecondaryActionButton(
                        title: series.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: series.isFavorite ? "heart.fill" : "heart",
                        action: toggleFavorite
                    )
                    Spacer(minLength: 0)
                }
            }
        }

        // MARK: - Episodes

        private var episodesSection: some View {
            VStack(alignment: .leading, spacing: 22) {
                TVSectionHeader(title: "Episodes")
                    .padding(.horizontal, TVDetailMetrics.horizontalInset)

                if availableSeasons.count > 1 {
                    seasonSelector
                }

                if series.episodes.isEmpty {
                    episodesPlaceholder
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: TVDetailMetrics.railSpacing) {
                            ForEach(seasonEpisodes) { episode in
                                TVEpisodeCard(
                                    episode: episode,
                                    onPlay: { playEpisode(episode) },
                                    onToggleWatched: { toggleWatched(episode) },
                                    onMarkPreviousWatched: { markPreviousWatched(episode) },
                                    onMarkFollowingUnwatched: { markFollowingUnwatched(episode) }
                                )
                            }
                        }
                        .padding(.horizontal, TVDetailMetrics.horizontalInset)
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                }
            }
            .focusSection()
        }

        private var seasonSelector: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(availableSeasons, id: \.self) { season in
                        Button("Season \(season)") {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedSeason = season }
                        }
                        .buttonStyle(TVChipButtonStyle(isSelected: season == selectedSeason))
                    }
                }
                .padding(.horizontal, TVDetailMetrics.horizontalInset)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .focusSection()
        }

        @ViewBuilder
        private var episodesPlaceholder: some View {
            if isLoadingEpisodes {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading episodes…")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                VStack(spacing: 16) {
                    Text("No episodes available")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Retry") { Task { await loadEpisodes() } }
                        .buttonStyle(TVChipButtonStyle(isSelected: false))
                }
            }
        }

        // MARK: - About / ratings / information

        private var aboutSection: some View {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 22) {
                    TVSectionHeader(title: "About")
                    if let plot = series.plot, !plot.isEmpty {
                        TVAboutText(text: plot)
                    } else {
                        Text("No description available.")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !informationItems.isEmpty {
                    TVInfoCard(title: "Information", items: informationItems)
                        .frame(width: 560)
                }
            }
            .padding(.horizontal, TVDetailMetrics.horizontalInset)
            .focusSection()
        }

        // MARK: - Rail items

        @ViewBuilder
        private func posterLink(for item: HomeMediaItem) -> some View {
            switch item {
            case let .movie(movie):
                NavigationLink(value: movie) {
                    TVPosterCard(title: item.title, imageURL: item.imageURL)
                }
                .buttonStyle(TVCardButtonStyle())
            case let .series(series):
                NavigationLink(value: series) {
                    TVPosterCard(title: item.title, imageURL: item.imageURL)
                }
                .buttonStyle(TVCardButtonStyle())
            case .live:
                EmptyView()
            }
        }

        // MARK: - Derived data

        private var rating5: Double {
            if let raw = series.rating5Based, let value = Double(raw), value > 0 { return min(value, 5) }
            if let raw = series.rating, let value = Double(raw), value > 0 { return min(value / 2, 5) }
            return 0
        }

        private var heroMetaItems: [TVMetaItem] {
            var items: [TVMetaItem] = []
            if let date = DetailFormat.date(from: series.releaseDate)
                ?? DetailFormat.year(from: series.releaseDate)
            {
                items.append(TVMetaItem(label: "Released", value: date))
            }
            if let genre = series.genre, !genre.isEmpty {
                items.append(TVMetaItem(label: "Genre", value: shortGenre(genre)))
            }
            if !availableSeasons.isEmpty {
                items.append(TVMetaItem(label: "Seasons", value: seasonCountLabel))
            }
            return items
        }

        private var informationItems: [TVMetaItem] {
            var items: [TVMetaItem] = []
            items.append(TVMetaItem(label: "Playlist Title", value: series.name))
            if let director = series.director, !director.isEmpty {
                items.append(TVMetaItem(label: "Creator", value: director))
            }
            if let genre = series.genre, !genre.isEmpty {
                items.append(TVMetaItem(label: "Genre", value: genre))
            }
            if let cast = series.cast, !cast.isEmpty, series.orderedCast.isEmpty {
                items.append(TVMetaItem(label: "Cast", value: cast))
            }
            if let cert = series.contentRating, !cert.isEmpty {
                items.append(TVMetaItem(label: "Rated", value: cert))
            }
            return items
        }

        private func shortGenre(_ genre: String) -> String {
            genre.split(separator: ",").prefix(2)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ")
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

        /// The furthest partially-watched (not completed) episode in the
        /// series, ordered by season then episode.
        private var furthestInProgressEpisode: Episode? {
            series.episodes
                .filter { $0.watchProgress > 1 && !$0.isWatched }
                .max { ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum) }
        }

        /// The furthest episode with any watch progress, including completed.
        private var furthestProgressEpisode: Episode? {
            series.episodes
                .filter { $0.watchProgress > 0 || $0.isWatched }
                .max { ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum) }
        }

        /// The episode the Play button starts: resume the furthest
        /// partially-watched episode, otherwise the first episode of the
        /// selected season.
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
            let parsed = await (try? manager.fetchEpisodes(
                seriesId: series.seriesId,
                seriesElementId: series.id,
                playlist: playlist
            )) ?? []
            // Insert through the view's own context, attaching to `series`, so its
            // episodes relationship — and this view — update synchronously. Writing
            // through a background context left the relationship stale until a later
            // cross-context merge, so episodes only appeared after navigating back.
            await MainActor.run { series.insertEpisodes(parsed, into: modelContext) }
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

        // MARK: - Actions

        private func playEpisode(_ episode: Episode) {
            guard let playlist = seriesPlaylist,
                  let media = PlayableMedia.from(episode: episode, playlist: playlist) else { return }
            playingMedia = media
        }

        private func toggleFavorite() {
            series.isFavorite.toggle()
            series.addedToWatchlistDate = series.isFavorite ? Date() : nil
        }

        private func toggleWatched(_ episode: Episode) {
            episode.setWatched(!episode.isWatched)
            try? modelContext.save()
        }

        private func markPreviousWatched(_ episode: Episode) {
            episode.markEarlierEpisodesWatched()
            try? modelContext.save()
        }

        private func markFollowingUnwatched(_ episode: Episode) {
            episode.markLaterEpisodesUnwatched()
            try? modelContext.save()
        }
    }

    // MARK: - Related titles

    private extension TVSeriesDetailView {
        func resolveSimilar() {
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

        func resolveOtherSources() {
            otherSources = OtherSources.resolve(for: series, in: modelContext)
        }
    }

    // MARK: - Season chip style

    /// A focusable selectable pill used by the season selector and small
    /// secondary actions.
    struct TVChipButtonStyle: ButtonStyle {
        var isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let highlighted = isFocused || isSelected
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(highlighted ? .black : .white)
                    .padding(.horizontal, 28)
                    .frame(height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(fill)
                    )
                    .scaleEffect(isFocused ? 1.06 : 1.0)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
                    .animation(.easeOut(duration: 0.18), value: isSelected)
            }

            private var fill: AnyShapeStyle {
                if isFocused { return AnyShapeStyle(.white) }
                if isSelected { return AnyShapeStyle(.white.opacity(0.85)) }
                return AnyShapeStyle(.regularMaterial)
            }
        }
    }

    #Preview("TV Series") {
        let container = previewContainer()
        let series = PreviewData.sampleSeries
        series.backdropPath = "/abc123backdrop.jpg"
        series.tagline = "All Hail the King."
        series.contentRating = "TV-MA"
        return NavigationStack {
            TVSeriesDetailView(series: series)
        }
        .modelContainer(container)
    }

#endif
