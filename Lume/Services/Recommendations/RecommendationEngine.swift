//
//  RecommendationEngine.swift
//  Lume
//
//  Builds the personalized "For You" list entirely on-device. Reads the user's
//  favorites, watch history and recommendation votes from the catalog, turns
//  the embeddings the content index already produced into a taste profile (see
//  RecommendationScoring), and ranks unwatched titles against it. Votes live on
//  the catalog models (`recommendationVoteRaw`, mirrored to `UserContentState`),
//  so they sync across devices via iCloud.
//
//  Runs off the main thread on its own background ModelContext, and never holds
//  a managed object across a suspension point — candidates are scored a page at
//  a time and only plain value results survive each page, so a huge catalog
//  costs a bounded amount of memory.
//

import Foundation
import SwiftData

/// Which catalog kind a recommendation points at. Live TV isn't indexed, so the
/// engine only ever produces movies and series.
enum RecommendedKind: String, Codable {
    case movie
    case series
}

/// A single ranked recommendation — just enough for the view to fetch the model
/// and present it.
struct ScoredRecommendation: Equatable, Codable {
    let id: String
    let kind: RecommendedKind
}

actor RecommendationEngine {
    /// How often the (expensive) ranking is actually recomputed. Between
    /// recomputes the cached list is reused — voting or watching still drops the
    /// acted-on card live, but the full re-rank waits for this interval. Adjust
    /// here to recompute more or less often.
    static let recalculationInterval: TimeInterval = 24 * 60 * 60 // once per day

    private let modelContainer: ModelContainer
    private let cacheStore: RecommendationCacheStore
    private let recalculationInterval: TimeInterval

    /// How many liked titles seed the taste profile. The whole favorites/history
    /// set is naturally small, but cap it so a power user's library still builds
    /// the profile from a bounded fetch.
    private let signalLimit = 200
    /// Candidates scored per page, then released — bounds peak memory regardless
    /// of catalog size.
    private let pageSize = 1000

    private let favoriteWeight: Float = 1.0
    private let watchedWeight: Float = 0.6

    private let upvote = RecommendationVote.upvote.rawValue
    private let downvote = RecommendationVote.downvote.rawValue

    init(
        modelContainer: ModelContainer,
        cacheStore: RecommendationCacheStore = RecommendationCacheStore(),
        recalculationInterval: TimeInterval = RecommendationEngine.recalculationInterval
    ) {
        self.modelContainer = modelContainer
        self.cacheStore = cacheStore
        self.recalculationInterval = recalculationInterval
    }

    /// The top `limit` unwatched titles for the active profile, best first.
    /// Candidates in `excludedCategoryIDs` (hidden in Content Management, or
    /// restricted for a child profile) never enter the ranking, so the row isn't
    /// filled with titles the caller has to drop again.
    ///
    /// Throttled: a non-empty list computed within `recalculationInterval` is
    /// returned from the cache instead of re-ranking the catalog. The caller
    /// re-validates each entry against live state, so a freshly watched, favorited
    /// or voted title still drops out between recomputes. Empty when the user has
    /// no taste signals yet — the caller then simply hides the row.
    ///
    /// With `groupsTitles`, each title appears once (its best-scoring copy) and
    /// a title any copy of which was watched, started, favorited or voted on is
    /// left out, as the grouped card would show that state. The caller picks
    /// which copy to show.
    func recommendations(
        limit: Int = 30,
        excluding excludedCategoryIDs: Set<String> = [],
        groupsTitles: Bool = LibrarySettings.groupDuplicateTitles()
    ) -> [ScoredRecommendation] {
        let profileID = ActiveProfileStore.current
        // Grouping changes which titles qualify, so it is part of the token.
        let visibility = ContentRestriction.visibilityToken(for: excludedCategoryIDs) + (groupsTitles ? "|grouped" : "")
        // A changed visibility set invalidates the cache: the list was ranked
        // against the previous one, so titles the user just un-hid would stay
        // missing until the interval elapsed.
        if let cached = cacheStore.cache(for: profileID),
           !cached.items.isEmpty,
           cached.visibilityToken == visibility,
           Date().timeIntervalSince(cached.computedAt) < recalculationInterval
        {
            return cached.items
        }

        guard let taste = RecommendationScoring.centroid(of: positiveSignals()) else {
            return []
        }
        let dislike = RecommendationScoring.centroid(of: dislikeSignals())
        let ranked = rankCandidates(
            limit: limit, taste: taste, dislike: dislike, excluding: excludedCategoryIDs, groupsTitles: groupsTitles
        )

        // Only cache a real result — an empty one means "no signal yet", which
        // should retry cheaply as soon as the user favorites or watches something.
        if !ranked.isEmpty {
            cacheStore.save(
                RecommendationCache(computedAt: Date(), items: ranked, visibilityToken: visibility),
                for: profileID
            )
        }
        return ranked
    }

    // MARK: - Taste profile

    /// Positive signals: favorited/watched/engaged titles (weighted by strength)
    /// plus any upvoted ones, each contributing its embedding to the taste
    /// centroid. Downvoted titles are skipped — a rejection outweighs a past
    /// watch.
    private func positiveSignals() -> [RecommendationScoring.Signal] {
        let context = ModelContext(modelContainer)
        let upvote = upvote
        let downvote = downvote
        var signals: [RecommendationScoring.Signal] = []

        var movies = FetchDescriptor<Movie>(
            predicate: #Predicate {
                $0.embeddingData != nil && $0.recommendationVoteRaw != downvote
                    && ($0.isFavorite || $0.isWatched || $0.lastWatchedDate != nil || $0.recommendationVoteRaw == upvote)
            },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        movies.fetchLimit = signalLimit
        for movie in (try? context.fetch(movies)) ?? [] {
            guard let vector = movie.embeddingData.map(TextEmbedder.decode) else { continue }
            let weight = (movie.isFavorite || movie.recommendationVoteRaw == upvote) ? favoriteWeight : watchedWeight
            signals.append(.init(vector: vector, weight: weight))
        }

        var series = FetchDescriptor<Series>(
            predicate: #Predicate {
                $0.embeddingData != nil && $0.recommendationVoteRaw != downvote
                    && ($0.isFavorite || $0.lastWatchedDate != nil || $0.recommendationVoteRaw == upvote)
            },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        series.fetchLimit = signalLimit
        for show in (try? context.fetch(series)) ?? [] {
            guard let vector = show.embeddingData.map(TextEmbedder.decode) else { continue }
            let weight = (show.isFavorite || show.recommendationVoteRaw == upvote) ? favoriteWeight : watchedWeight
            signals.append(.init(vector: vector, weight: weight))
        }

        return signals
    }

    /// Disliked signals: embeddings of downvoted titles, so the engine can steer
    /// away from content the user has rejected.
    private func dislikeSignals() -> [RecommendationScoring.Signal] {
        let context = ModelContext(modelContainer)
        let downvote = downvote
        var signals: [RecommendationScoring.Signal] = []

        let movies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.embeddingData != nil && $0.recommendationVoteRaw == downvote }
        )
        for movie in (try? context.fetch(movies)) ?? [] {
            if let vector = movie.embeddingData.map(TextEmbedder.decode) {
                signals.append(.init(vector: vector, weight: 1))
            }
        }

        let series = FetchDescriptor<Series>(
            predicate: #Predicate { $0.embeddingData != nil && $0.recommendationVoteRaw == downvote }
        )
        for show in (try? context.fetch(series)) ?? [] {
            if let vector = show.embeddingData.map(TextEmbedder.decode) {
                signals.append(.init(vector: vector, weight: 1))
            }
        }

        return signals
    }

    // MARK: - Candidate ranking

    /// Scores every unwatched, visible candidate against the taste profile a page
    /// at a time, keeping only the running top `limit`. The pages already walk
    /// the whole candidate set, so the category exclusion is applied in memory
    /// rather than widening the (index-served) predicate.
    private func rankCandidates(
        limit: Int, taste: [Float], dislike: [Float]?, excluding excluded: Set<String>, groupsTitles: Bool
    ) -> [ScoredRecommendation] {
        var top: [(item: ScoredRecommendation, title: String?, score: Float)] = []
        let actedOn = groupsTitles ? actedOnTitles() : (movies: [], series: [])

        func consider(_ id: String, _ kind: RecommendedKind, _ titleGroupKey: String?, _ score: Float) {
            let title = groupsTitles ? titleGroupKey : nil
            if let title {
                let acted = kind == .movie ? actedOn.movies : actedOn.series
                guard !acted.contains(title) else { return }
            }
            if let title, let held = top.firstIndex(where: { $0.item.kind == kind && $0.title == title }) {
                guard score > top[held].score else { return }
                top.remove(at: held)
            } else {
                guard top.count < limit || score > top.last!.score else { return }
            }
            top.append((ScoredRecommendation(id: id, kind: kind), title, score))
            top.sort { $0.score > $1.score }
            if top.count > limit { top.removeLast() }
        }

        // Movies: unwatched, not favorited, never opened, not yet voted on (a
        // voted title — up or down — has already left the rail).
        forEachPage(idOf: { (movie: Movie) in movie.id }, page: { cursor, limit in
            Self.movieCandidates(cursor: cursor, limit: limit)
        }, body: { movie in
            guard !excluded.contains(movie.categoryId ?? ""),
                  let vector = movie.embeddingData.map(TextEmbedder.decode) else { return }
            let score = RecommendationScoring.score(candidate: vector, taste: taste, dislike: dislike)
            consider(movie.id, .movie, movie.titleGroupKey, score)
        })

        // Series: not favorited, never opened, not yet voted on.
        forEachPage(idOf: { (show: Series) in show.id }, page: { cursor, limit in
            Self.seriesCandidates(cursor: cursor, limit: limit)
        }, body: { show in
            guard !excluded.contains(show.categoryId ?? ""),
                  let vector = show.embeddingData.map(TextEmbedder.decode) else { return }
            let score = RecommendationScoring.score(candidate: vector, taste: taste, dislike: dislike)
            consider(show.id, .series, show.titleGroupKey, score)
        })

        return top.map(\.item)
    }

    private static func movieCandidates(cursor: String, limit: Int) -> FetchDescriptor<Movie> {
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate {
                $0.embeddingData != nil && !$0.isWatched && !$0.isFavorite
                    && $0.lastWatchedDate == nil && $0.recommendationVoteRaw == 0 && $0.id > cursor
            },
            sortBy: [SortDescriptor(\.id, comparator: .lexical)]
        )
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = [\.id, \.categoryId, \.embeddingData, \.titleGroupKey]
        return descriptor
    }

    private static func seriesCandidates(cursor: String, limit: Int) -> FetchDescriptor<Series> {
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate {
                $0.embeddingData != nil && !$0.isFavorite
                    && $0.lastWatchedDate == nil && $0.recommendationVoteRaw == 0 && $0.id > cursor
            },
            sortBy: [SortDescriptor(\.id, comparator: .lexical)]
        )
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = [\.id, \.categoryId, \.embeddingData, \.titleGroupKey]
        return descriptor
    }

    /// Titles a copy of which carries user state, the same state that keeps a
    /// row itself out of the candidate pages. One fetch per kind.
    private func actedOnTitles() -> (movies: Set<String>, series: Set<String>) {
        let context = ModelContext(modelContainer)
        var movies = FetchDescriptor<Movie>(
            predicate: #Predicate {
                $0.titleGroupKey != nil
                    && ($0.isWatched || $0.isFavorite || $0.lastWatchedDate != nil || $0.recommendationVoteRaw != 0)
            }
        )
        movies.propertiesToFetch = [\.titleGroupKey]
        var series = FetchDescriptor<Series>(
            predicate: #Predicate {
                $0.titleGroupKey != nil && ($0.isFavorite || $0.lastWatchedDate != nil || $0.recommendationVoteRaw != 0)
            }
        )
        series.propertiesToFetch = [\.titleGroupKey]
        return (
            Set(((try? context.fetch(movies)) ?? []).compactMap(\.titleGroupKey)),
            Set(((try? context.fetch(series)) ?? []).compactMap(\.titleGroupKey))
        )
    }

    /// Walks every matching row `pageSize` at a time on a fresh context per page,
    /// so no managed object outlives the page it came from — what keeps peak
    /// memory bounded regardless of catalog size.
    ///
    /// Pages are keyed on the last id seen, never on `fetchOffset`: an offset
    /// makes SQLite re-walk every row it skips, so a 179k-row catalog cost
    /// roughly the square of its page count — tens of seconds on a Mac. `page`
    /// must ask for `id > cursor` ordered by `id` with `comparator: .lexical`,
    /// the byte order `>` compares in and the unique `id` index holds; the
    /// default comparator is number-aware and would skip rows (see
    /// `ContentSyncManager.sweepPaged`). The empty string sorts before every id.
    private func forEachPage<Model: PersistentModel>(
        idOf: (Model) -> String,
        page: (_ cursor: String, _ limit: Int) -> FetchDescriptor<Model>,
        body: (Model) -> Void
    ) {
        var cursor = ""
        while true {
            let context = ModelContext(modelContainer)
            let rows = (try? context.fetch(page(cursor, pageSize))) ?? []
            rows.forEach(body)
            guard rows.count == pageSize, let last = rows.last else { return }
            cursor = idOf(last)
        }
    }
}
