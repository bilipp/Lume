//
//  RecommendationTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct RecommendationScoringTests {
    @Test func `cosine similarity is 1 for identical, -1 for opposite, 0 for orthogonal`() {
        #expect(abs(RecommendationScoring.cosineSimilarity([1, 0, 0], [1, 0, 0]) - 1) < 1e-5)
        #expect(abs(RecommendationScoring.cosineSimilarity([1, 0, 0], [-1, 0, 0]) + 1) < 1e-5)
        #expect(abs(RecommendationScoring.cosineSimilarity([1, 0, 0], [0, 1, 0])) < 1e-5)
    }

    @Test func `cosine similarity is 0 for empty or mismatched vectors`() {
        #expect(RecommendationScoring.cosineSimilarity([], []) == 0)
        #expect(RecommendationScoring.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
        #expect(RecommendationScoring.cosineSimilarity([0, 0], [1, 1]) == 0)
    }

    @Test func `centroid returns nil when there is no usable signal`() {
        #expect(RecommendationScoring.centroid(of: []) == nil)
        #expect(RecommendationScoring.centroid(of: [.init(vector: [0, 0, 0], weight: 1)]) == nil)
        #expect(RecommendationScoring.centroid(of: [.init(vector: [1, 0], weight: 0)]) == nil)
    }

    @Test func `centroid is unit length and pulled toward the heavier signal`() throws {
        let centroid = try #require(RecommendationScoring.centroid(of: [
            .init(vector: [1, 0], weight: 3),
            .init(vector: [0, 1], weight: 1)
        ]))
        let norm = (centroid[0] * centroid[0] + centroid[1] * centroid[1]).squareRoot()
        #expect(abs(norm - 1) < 1e-5)
        #expect(centroid[0] > centroid[1])
    }

    @Test func `disliked content is penalized in the score`() {
        let candidate: [Float] = [1, 0]
        let taste: [Float] = [1, 0]
        let withoutDislike = RecommendationScoring.score(candidate: candidate, taste: taste, dislike: nil)
        let withDislike = RecommendationScoring.score(candidate: candidate, taste: taste, dislike: [1, 0])
        #expect(withDislike < withoutDislike)
    }
}

@MainActor
@Suite(.serialized)
struct RecommendationEngineTests {
    private func makeMovie(
        _ container: ModelContainer,
        id: String,
        vector: [Float],
        favorite: Bool = false,
        watched: Bool = false,
        vote: RecommendationVote? = nil
    ) {
        let movie = Movie(id: id, streamId: 1, name: id)
        movie.embeddingData = TextEmbedder.encode(vector)
        movie.indexedAt = Date()
        movie.isFavorite = favorite
        movie.isWatched = watched
        movie.recommendationVote = vote
        container.mainContext.insert(movie)
    }

    @Test func `recommends unwatched titles similar to a favorite and excludes watched ones`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0])
        makeMovie(container, id: "different", vector: [0, 0, 0, 1])
        makeMovie(container, id: "watched-similar", vector: [0.95, 0.05, 0, 0], watched: true)
        try container.mainContext.save()

        let engine = RecommendationEngine(modelContainer: container)
        let result = await engine.recommendations()
        let ids = result.map(\.id)

        #expect(ids.contains("similar"))
        #expect(!ids.contains("liked")) // favorites aren't re-suggested
        #expect(!ids.contains("watched-similar")) // watched titles are removed
        #expect(ids.first == "similar") // most similar ranks first
    }

    @Test func `returns nothing without any taste signal`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "a", vector: [1, 0, 0, 0])
        makeMovie(container, id: "b", vector: [0, 1, 0, 0])
        try container.mainContext.save()

        let engine = RecommendationEngine(modelContainer: container)
        #expect(await engine.recommendations().isEmpty)
    }

    @Test func `downvoted titles are excluded`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0], vote: .downvote)
        try container.mainContext.save()

        let engine = RecommendationEngine(modelContainer: container)
        let ids = await engine.recommendations().map(\.id)
        #expect(!ids.contains("similar"))
    }

    @Test func `an upvote alone is a taste signal`() async throws {
        let container = try makeTestContainer()
        // No favorites or watch history — only an upvote seeds the taste profile.
        makeMovie(container, id: "upvoted", vector: [1, 0, 0, 0], vote: .upvote)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0])
        makeMovie(container, id: "different", vector: [0, 0, 0, 1])
        try container.mainContext.save()

        let engine = RecommendationEngine(modelContainer: container)
        let ids = await engine.recommendations().map(\.id)
        #expect(ids.first == "similar")
    }
}
