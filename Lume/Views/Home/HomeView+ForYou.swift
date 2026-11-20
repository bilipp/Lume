//
//  HomeView+ForYou.swift
//  Lume
//
//  The For You rail: loading, grouping and voting on recommendations
//

import SwiftData
import SwiftUI

// MARK: - For You

extension HomeView {
    /// The immersive tvOS home's hero selection; inert elsewhere.
    var heroSelection: Binding<HeroItem?> {
        #if os(tvOS)
            $selectedHero
        #else
            .constant(nil)
        #endif
    }

    /// Multi-View launched from a rail; tvOS presents it through the router.
    var multiViewLaunchSelection: Binding<MultiViewLaunch?> {
        #if os(tvOS)
            .constant(nil)
        #else
            $multiViewLaunch
        #endif
    }

    /// Refresh the row when the active playlist, the favorites/history queries or
    /// the hidden categories change. This only re-resolves the list (cheap, and
    /// re-validates each entry against live state) — the engine still throttles the actual re-ranking to
    /// its recalculation interval.
    var recommendationsKey: String {
        let counts = "\(watchedMovies.count)-\(watchedSeries.count)-\(favoriteMovies.count)-\(favoriteSeries.count)"
        let visibility = restriction.visibilityToken
        return "rec-\(recommendationsEnabled)-\(premium.isPremium)-\(isSyncBusy)-\(recommendationsRecalcToken)-\(counts)-\(catalogScope.token)-\(visibility)"
    }

    /// True while a playlist sync, iCloud sync or EPG import is running. The For
    /// You recompute reads and ranks the whole catalog, so on older devices it's
    /// deferred until those finish — and during a CloudKit import, touching the
    /// catalog mid-handshake is best avoided entirely. Folded into
    /// `recommendationsKey` so the load retries the moment syncing settles.
    var isSyncBusy: Bool {
        playlists.contains { $0.syncStatus == .syncing }
            || indexing.isCloudSyncActive
            || epgSync.isSyncing
    }

    /// Resolves the engine's (throttled, possibly cached) list to local models,
    /// dropping any that are no longer recommendable — watched, favorited or
    /// voted on since the list was computed. That live re-validation is what lets
    /// a vote remove a card without forcing a full re-rank.
    func loadRecommendations() async {
        guard recommendationsEnabled, premium.isPremium else {
            recommendations = []
            return
        }
        // Don't calculate while syncing — leave whatever is already shown (or the
        // loading placeholder) in place; the task re-fires once `isSyncBusy` clears.
        guard !isSyncBusy else { return }

        let interval = Perf.begin(.homeRecommendations)
        defer { Perf.end(interval) }

        let engine = RecommendationEngine(modelContainer: modelContext.container)
        let grouped = groupDuplicateTitles
        let scored = await engine.recommendations(excluding: restriction.excludedCategoryIDs, groupsTitles: grouped)
        // Grouped, the engine names one copy per title, which may sit in a
        // playlist outside the scope; `groupedRecommendations` swaps in an
        // in-scope copy or drops the title.
        let movieRows = fetchMovies(ids: scored.filter { $0.kind == .movie }.map(\.id), anyCopyInScope: grouped)
        let seriesRows = fetchSeries(ids: scored.filter { $0.kind == .series }.map(\.id), anyCopyInScope: grouped)
        var items: [HomeMediaItem] = []
        var titles = Set<String>()
        for recommendation in scored {
            let item: HomeMediaItem? = switch recommendation.kind {
            case .movie:
                movieRows[recommendation.id].flatMap { isRecommendable($0) ? .movie($0) : nil }
            case .series:
                seriesRows[recommendation.id].flatMap { isRecommendable($0) ? .series($0) : nil }
            }
            guard let item else { continue }
            if grouped, let title = item.titleGroupID, !titles.insert(title).inserted { continue }
            items.append(item)
            if items.count >= Self.recommendationCandidates(grouped: grouped) { break }
        }
        recommendations = grouped ? groupedRecommendations(items) : items
        recommendationsLoaded = true
    }

    /// Grouped, a title is only recommendable when no copy of it was watched,
    /// started or favorited, so the row reads more candidates than it shows.
    static func recommendationCandidates(grouped: Bool) -> Int {
        grouped ? 30 : 10
    }

    /// The first ten candidates no copy of which has user state, each shown as
    /// its title's representative copy. One fetch per kind for the state and
    /// one for the copies.
    func groupedRecommendations(_ candidates: [HomeMediaItem]) -> [HomeMediaItem] {
        var request = TitleGroupStates.Request()
        request.add(candidates)
        let states = TitleGroupStates.load(for: request, in: modelContext)
        let fresh = candidates.filter { item in
            let state: TitleGroupState = switch item {
            case let .movie(movie): states.state(of: movie)
            case let .series(series): states.state(of: series)
            case .live: .empty
            }
            return !state.isFavorite && !state.isWatched && state.lastWatched == nil
        }

        let ranking = titleRanking
        let movieCopies = siblingMovies(keys: request.movieKeys)
        let seriesCopies = siblingSeries(keys: request.seriesKeys)
        let scope = scopeMatcher
        let shown = fresh.compactMap { item -> HomeMediaItem? in
            switch item {
            case let .movie(movie):
                guard let key = movie.titleGroupKey, let copies = movieCopies[key] else {
                    return scope.contains(movie.id, .movies) ? item : nil
                }
                return .movie(ranking.best(of: copies))
            case let .series(series):
                guard let key = series.titleGroupKey, let copies = seriesCopies[key] else {
                    return scope.contains(series.id, .series) ? item : nil
                }
                return .series(ranking.best(of: copies))
            case .live:
                return item
            }
        }
        return Array(shown.prefix(10))
    }

    /// In-scope, visible copies of the given titles, by key.
    /// Only what ranking needs is fetched; a card faults in the rest of the
    /// copy it shows.
    func siblingMovies(keys: Set<String>) -> [String: [Movie]] {
        let scope = scopeMatcher
        let rows = siblingKeyChunks(keys).flatMap { chunk -> [Movie] in
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { chunk.contains($0.titleGroupKey) })
            descriptor.propertiesToFetch = [\.id, \.name, \.categoryId, \.titleGroupKey]
            return (try? modelContext.fetch(descriptor)) ?? []
        }
        .filter { scope.contains($0.id, .movies) && !restriction.hides(categoryID: $0.categoryId) }
        return Dictionary(grouping: rows) { $0.titleGroupKey ?? "" }
    }

    func siblingSeries(keys: Set<String>) -> [String: [Series]] {
        let scope = scopeMatcher
        let rows = siblingKeyChunks(keys).flatMap { chunk -> [Series] in
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate { chunk.contains($0.titleGroupKey) })
            descriptor.propertiesToFetch = [\.id, \.name, \.categoryId, \.titleGroupKey]
            return (try? modelContext.fetch(descriptor)) ?? []
        }
        .filter { scope.contains($0.id, .series) && !restriction.hides(categoryID: $0.categoryId) }
        return Dictionary(grouping: rows) { $0.titleGroupKey ?? "" }
    }

    /// `keys` in SQLite-safe chunks, as `String?` for a plain `IN` on the
    /// optional column.
    private func siblingKeyChunks(_ keys: Set<String>) -> [Set<String?>] {
        let all = Array(keys)
        return stride(from: 0, to: all.count, by: 500).map { start in
            Set(all[start ..< min(start + 500, all.count)].map(Optional.some))
        }
    }

    func isRecommendable(_ movie: Movie) -> Bool {
        !movie.isWatched && !movie.isFavorite && movie.lastWatchedDate == nil && movie.recommendationVote == nil
    }

    func isRecommendable(_ series: Series) -> Bool {
        !series.isFavorite && series.lastWatchedDate == nil && series.recommendationVote == nil
    }

    /// The rows with `ids` the viewer may see, by id, in one fetch.
    /// - Parameter anyCopyInScope: also return an out-of-scope row of a
    ///   grouped title, for the caller to replace with an in-scope copy.
    func fetchMovies(ids: [String], anyCopyInScope: Bool) -> [String: Movie] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let scope = scopeMatcher
        let rows = ((try? modelContext.fetch(FetchDescriptor<Movie>(predicate: #Predicate { wanted.contains($0.id) }))) ?? [])
            .filter { movie in
                (scope.contains(movie.id, .movies) || (anyCopyInScope && movie.titleGroupKey != nil))
                    && !restriction.hides(categoryID: movie.categoryId)
            }
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func fetchSeries(ids: [String], anyCopyInScope: Bool) -> [String: Series] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let scope = scopeMatcher
        let rows = ((try? modelContext.fetch(FetchDescriptor<Series>(predicate: #Predicate { wanted.contains($0.id) }))) ?? [])
            .filter { series in
                (scope.contains(series.id, .series) || (anyCopyInScope && series.titleGroupKey != nil))
                    && !restriction.hides(categoryID: series.categoryId)
            }
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Records an up/down vote for a recommendation. Either vote drops the title
    /// from the row immediately (it's been acted on) and steers the next recompute
    /// — an upvote pulls the taste profile toward it, a downvote away. The vote is
    /// persisted now; the engine folds it in on its next (throttled) recompute.
    func vote(_ item: HomeMediaItem, _ vote: RecommendationVote) {
        switch item {
        case let .movie(movie): movie.recommendationVote = vote
        case let .series(series): series.recommendationVote = vote
        case .live: return
        }
        // Persisted on the catalog model like favorites/watch state; the iCloud
        // reconciler mirrors it to UserContentState so the vote syncs.
        try? modelContext.save()

        recommendations.removeAll { $0.id == item.id }
    }
}
