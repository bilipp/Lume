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
enum RecommendedKind {
    case movie
    case series
}

/// A single ranked recommendation — just enough for the view to fetch the model
/// and present it.
struct ScoredRecommendation: Equatable {
    let id: String
    let kind: RecommendedKind
}

actor RecommendationEngine {
    private let modelContainer: ModelContainer

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

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// The top `limit` unwatched titles for the active profile, best first.
    /// Empty when the user has no taste signals yet (nothing favorited, watched
    /// or upvoted with an embedding) — the caller then simply hides the row.
    func recommendations(limit: Int = 30) -> [ScoredRecommendation] {
        guard let taste = RecommendationScoring.centroid(of: positiveSignals()) else {
            return []
        }
        let dislike = RecommendationScoring.centroid(of: dislikeSignals())
        return rankCandidates(limit: limit, taste: taste, dislike: dislike)
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

    /// Scores every unwatched candidate against the taste profile a page at a
    /// time, keeping only the running top `limit`.
    private func rankCandidates(limit: Int, taste: [Float], dislike: [Float]?) -> [ScoredRecommendation] {
        var top: [(item: ScoredRecommendation, score: Float)] = []

        func consider(_ id: String, _ kind: RecommendedKind, _ score: Float) {
            guard top.count < limit || score > top.last!.score else { return }
            top.append((ScoredRecommendation(id: id, kind: kind), score))
            top.sort { $0.score > $1.score }
            if top.count > limit { top.removeLast() }
        }

        // Movies: unwatched, not favorited, never opened, not yet voted on (a
        // voted title — up or down — has already left the rail).
        var movieOffset = 0
        while true {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.embeddingData != nil && !$0.isWatched && !$0.isFavorite
                        && $0.lastWatchedDate == nil && $0.recommendationVoteRaw == 0
                },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = movieOffset
            descriptor.fetchLimit = pageSize
            let page = (try? context.fetch(descriptor)) ?? []
            for movie in page {
                guard let vector = movie.embeddingData.map(TextEmbedder.decode) else { continue }
                consider(movie.id, .movie, RecommendationScoring.score(candidate: vector, taste: taste, dislike: dislike))
            }
            if page.count < pageSize { break }
            movieOffset += pageSize
        }

        // Series: not favorited, never opened, not yet voted on.
        var seriesOffset = 0
        while true {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.embeddingData != nil && !$0.isFavorite
                        && $0.lastWatchedDate == nil && $0.recommendationVoteRaw == 0
                },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = seriesOffset
            descriptor.fetchLimit = pageSize
            let page = (try? context.fetch(descriptor)) ?? []
            for show in page {
                guard let vector = show.embeddingData.map(TextEmbedder.decode) else { continue }
                consider(show.id, .series, RecommendationScoring.score(candidate: vector, taste: taste, dislike: dislike))
            }
            if page.count < pageSize { break }
            seriesOffset += pageSize
        }

        return top.map(\.item)
    }
}
