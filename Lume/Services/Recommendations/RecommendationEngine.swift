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
    func recommendations(limit: Int = 30, excluding excludedCategoryIDs: Set<String> = []) -> [ScoredRecommendation] {
        let profileID = ActiveProfileStore.current
        let visibility = ContentRestriction.visibilityToken(for: excludedCategoryIDs)
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
            limit: limit, taste: taste, dislike: dislike, excluding: excludedCategoryIDs
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
        limit: Int, taste: [Float], dislike: [Float]?, excluding excluded: Set<String>
    ) -> [ScoredRecommendation] {
        var top: [(item: ScoredRecommendation, score: Float)] = []

        func consider(_ id: String, _ kind: RecommendedKind, _ score: Float) {
            guard top.count < limit || score > top.last!.score else { return }
            top.append((ScoredRecommendation(id: id, kind: kind), score))
            top.sort { $0.score > $1.score }
            if top.count > limit { top.removeLast() }
        }

        // Movies: unwatched, not favorited, never opened, not yet voted on (a
        // voted title — up or down — has already left the rail).
        forEachPage(predicate: #Predicate<Movie> {
            $0.embeddingData != nil && !$0.isWatched && !$0.isFavorite
                && $0.lastWatchedDate == nil && $0.recommendationVoteRaw == 0
        }, sortBy: [SortDescriptor(\.id)]) { movie in
            guard !excluded.contains(movie.categoryId ?? ""),
                  let vector = movie.embeddingData.map(TextEmbedder.decode) else { return }
            consider(movie.id, .movie, RecommendationScoring.score(candidate: vector, taste: taste, dislike: dislike))
        }

        // Series: not favorited, never opened, not yet voted on.
        forEachPage(predicate: #Predicate<Series> {
            $0.embeddingData != nil && !$0.isFavorite
                && $0.lastWatchedDate == nil && $0.recommendationVoteRaw == 0
        }, sortBy: [SortDescriptor(\.id)]) { show in
            guard !excluded.contains(show.categoryId ?? ""),
                  let vector = show.embeddingData.map(TextEmbedder.decode) else { return }
            consider(show.id, .series, RecommendationScoring.score(candidate: vector, taste: taste, dislike: dislike))
        }

        return top.map(\.item)
    }

    /// Walks every matching row `pageSize` at a time on a fresh context per page,
    /// so no managed object outlives the page it came from — what keeps peak
    /// memory bounded regardless of catalog size. `sortBy` must be stable, or
    /// offset paging would skip or repeat rows.
    private func forEachPage<Model: PersistentModel>(
        predicate: Predicate<Model>,
        sortBy: [SortDescriptor<Model>],
        body: (Model) -> Void
    ) {
        var offset = 0
        while true {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<Model>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? context.fetch(descriptor)) ?? []
            page.forEach(body)
            if page.count < pageSize {
                return
            }
            offset += pageSize
        }
    }
}
