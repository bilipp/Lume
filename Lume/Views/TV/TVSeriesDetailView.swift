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

        @Environment(\.modelContext) var modelContext
        @Environment(\.catalogScope) var catalogScope
        @Environment(\.contentRestriction) var contentRestriction
        @AppStorage(LibrarySettings.groupDuplicateTitlesKey)
        private var groupDuplicateTitles = LibrarySettings.groupDuplicateTitlesDefault
        @Query var playlists: [Playlist]

        @State var selectedSeason: Int = 1
        /// Season numbers and per-season episodes, cached so the body doesn't
        /// re-sort every episode on each render (see `recomputeSeasons`).
        @State private var availableSeasons: [Int] = []
        @State private var episodesBySeason: [Int: [Episode]] = [:]
        /// The series row whose episodes are being fetched.
        @State private var loadingSeriesID: String?
        @State var playingMedia: PlayableMedia?
        /// A pick made in the source picker, played once the picker has gone.
        @State var pendingPick: VODSourceOption?
        @State var sourcePicker: ContentSourcePickerRequest?
        /// Whether the open picker switches the copy on screen instead of playing.
        @State var isSwitchingSource = false
        @State var sourceOptions: [VODSourceOption] = []
        /// Copies that failed on every engine since the screen opened.
        @State var failedSourceIDs: Set<String> = []
        /// The copy of the title whose seasons and episodes the screen shows and
        /// plays; nil until the sources are resolved.
        @State var activeSeries: Series?
        /// Favorite and last-watched copy across every copy of the title.
        @State var groupStates: [String: TitleGroupState] = [:]
        @State private var similar: [HomeMediaItem] = []
        /// Favorite state across every copy of each rail title.
        @State private var railGroupStates = TitleGroupStates.empty
        @State private var refreshToken: UUID = .init()
        @State private var siblingCast: [CastMember] = []
        @State private var isLoadingTMDB: Bool
        @State private var showYouTubeUnavailable = false

        enum FocusTarget: Hashable {
            case play
            case source
            case season(Int)
            case episode(String)
        }

        @FocusState var focus: FocusTarget?

        init(series: Series) {
            self.series = series
            let needsFetch = series.titleTMDBId != nil && TMDBClient.shared.isConfigured && !series.hasFreshTMDBDetails()
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
            .fullScreenCover(item: $playingMedia, onDismiss: takeSourceFailure) { media in
                FullScreenPlayerView(media: media)
            }
            .contentSourcePicker($sourcePicker, onDismiss: sourcePickerDidClose) { pickedSource($0) }
            .alert("YouTube Unavailable", isPresented: $showYouTubeUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Install the YouTube app on your Apple TV to watch trailers.")
            }
            .task(id: series.id) {
                resolveSources()
                refreshGroupState()
                activeSeries = initialSource()
                await loadEpisodesIfNeeded()
                let freshSibling = TitleEnrichmentSiblings.freshTMDBSibling(of: series)
                await enrichIfNeeded(freshSibling: freshSibling)
                siblingCast = series.castMembers.isEmpty ? freshSibling?.orderedCast ?? [] : []
                await enrichSeriesRatingsIfNeeded(series, context: modelContext)
                resolveSimilar()
                withAnimation(.easeInOut(duration: 0.3)) {
                    isLoadingTMDB = false
                }
                // Episodes are now loaded, so the Play button is enabled and can
                // accept focus (an assignment made before this point is ignored
                // by the focus engine while the button is disabled).
                focus = .play
            }
            // Separate task so a stale-cache refresh runs alongside the
            // enrichment chain above instead of delaying the first paint, and
            // still gets cancelled when the screen goes away.
            .task(id: activeSeries?.id) { await refreshEpisodesIfStale() }
            .onChange(of: series.similarTMDBIds) { resolveSimilar() }
            .onChange(of: refreshToken) { resolveSimilar() }
            .onChange(of: shown.episodes.count) { recomputeSeasons() }
            .onChange(of: playingMedia == nil) { _, isNil in
                if isNil { refreshGroupState() }
            }
            .onChange(of: sourcesKey) { resolveSources() }
        }

        private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: TVDetailMetrics.sectionSpacing) {
                    hero

                    episodesSection

                    aboutSection

                    if !displayedCast.isEmpty {
                        TVRail(title: "Cast", items: displayedCast) { member in
                            TVCastCard(member: member)
                        }
                    }

                    if !series.trailers.isEmpty {
                        TVRail(title: "Videos", items: series.trailers) { video in
                            TVVideoCard(video: video) {
                                openVideo(video) { showYouTubeUnavailable = true }
                            }
                        }
                    }

                    if !similar.isEmpty {
                        TVRail(title: "You May Also Like", items: similar) { item in
                            posterLink(for: item)
                                .railFavoriteMenu(item, in: modelContext, groupStates: $railGroupStates)
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, .play)
            .task(id: similar) {
                railGroupStates = TitleGroupStates.load(for: similar, in: modelContext)
            }
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
                    isEnabled: isPlayable,
                    chooseSource: sourceOptions.isEmpty ? nil : { playNext(forcePicker: true) },
                    action: { playNext() }
                )
                .focused($focus, equals: .play)
                .missingPlaylistNotice(seriesPlaylist == nil && sourceOptions.isEmpty)
                HStack(spacing: 18) {
                    TVSecondaryActionButton(
                        title: groupState.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: groupState.isFavorite ? "heart.fill" : "heart",
                        action: toggleFavorite
                    )
                    if sourceOptions.count > 1 {
                        sourceSwitcher
                    }
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

                if shown.episodes.isEmpty {
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
                                .focused($focus, equals: .episode(episode.id))
                            }
                        }
                        .padding(.horizontal, TVDetailMetrics.horizontalInset)
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                    // When focus moves INTO the rail (e.g. down from Play), the
                    // enclosing focus section would otherwise pick the card
                    // nearest the SECTION's center — mid-rail, not the first
                    // episode. `.userInitiated` re-applies this default on
                    // user-driven entry, not just on appearance.
                    .defaultFocus(
                        $focus,
                        .episode(seasonEpisodes.first?.id ?? ""),
                        priority: .userInitiated
                    )
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
                        .focused($focus, equals: .season(season))
                    }
                }
                .padding(.horizontal, TVDetailMetrics.horizontalInset)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .focusSection()
            // Entering the selector lands on the CURRENT season's chip, not
            // whichever chip the focus section's center-pick would choose.
            .defaultFocus($focus, .season(selectedSeason), priority: .userInitiated)
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

                    if !series.externalRatings.isEmpty {
                        TVExternalRatingsView(ratings: series.externalRatings)
                            .padding(.top, 8)
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
                ?? DetailFormat.year(releaseDate: series.releaseDate, name: series.name)
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
            if let cast = series.cast, !cast.isEmpty, displayedCast.isEmpty {
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

        /// Runs only when episodes are added or removed; their numbers never change.
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

        /// Play button target — see `SeriesEpisodeProgress.nextEpisode`. Read
        /// more than once per body evaluation (play button + `playTitle`), so
        /// it must stay O(episodes) with no sorting.
        var nextEpisode: Episode? {
            SeriesEpisodeProgress.nextEpisode(in: shown.episodes, fallback: seasonEpisodes.first)
        }

        private var playTitle: LocalizedStringKey {
            guard let episode = nextEpisode else { return "Play" }
            if !episode.isWatched, episode.watchProgress > 1 {
                return "Resume S\(episode.seasonNum) E\(episode.episodeNum)"
            }
            return "Play S\(episode.seasonNum) E\(episode.episodeNum)"
        }

        /// The playlist that owns the copy on screen, which plays its episodes.
        var seriesPlaylist: Playlist? {
            playlists.owner(ofContentID: shown.id)
        }

        private var isPlayable: Bool {
            (nextEpisode != nil && seriesPlaylist != nil) || !sourceOptions.isEmpty
        }

        private var isLoadingEpisodes: Bool {
            loadingSeriesID == shown.id
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
            await loadEpisodes(resetsSeason: false)
        }

        /// - Parameter resetsSeason: whether to re-pick the season to open on.
        ///   False for a background refresh, which must not yank the selector
        ///   out from under someone browsing a season.
        private func loadEpisodes(resetsSeason: Bool = true) async {
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
            // episodes relationship — and this view — update synchronously. Writing
            // through a background context left the relationship stale until a later
            // cross-context merge, so episodes only appeared after navigating back.
            await MainActor.run { target.insertEpisodes(parsed, into: modelContext) }
            if resetsSeason, shown.id == target.id {
                selectedSeason = determineDefaultSeason()
            }
        }

        private func enrichIfNeeded(freshSibling: Series?) async {
            guard let tmdbId = series.titleTMDBId, !series.hasFreshTMDBDetails(freshSibling: freshSibling) else { return }
            let manager = ContentSyncManager(modelContainer: modelContext.container)
            await manager.enrichSeries(id: series.id, tmdbId: tmdbId)
            refreshToken = UUID()
        }
    }

    // MARK: - Actions & related titles

    private extension TVSeriesDetailView {
        var displayedCast: [CastMember] {
            series.castMembers.isEmpty ? siblingCast : series.orderedCast
        }

        func toggleWatched(_ episode: Episode) {
            episode.setWatched(!episode.isWatched)
            WatchedTrackers.sync(episode: episode, watched: episode.isWatched)
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
