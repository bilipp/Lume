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
        vote: RecommendationVote? = nil,
        category: String? = nil
    ) {
        let movie = Movie(id: id, streamId: 1, name: id)
        movie.embeddingData = TextEmbedder.encode(vector)
        movie.indexedAt = Date()
        movie.isFavorite = favorite
        movie.isWatched = watched
        movie.recommendationVote = vote
        movie.categoryId = category
        container.mainContext.insert(movie)
    }

    /// A cache backed by a throwaway defaults domain, so each test starts cold
    /// and never touches `.standard`.
    private func isolatedStore() -> RecommendationCacheStore {
        RecommendationCacheStore(defaults: UserDefaults(suiteName: "rec-test-\(UUID().uuidString)")!)
    }

    private func makeEngine(
        _ container: ModelContainer,
        cacheStore: RecommendationCacheStore? = nil,
        interval: TimeInterval = RecommendationEngine.recalculationInterval
    ) -> RecommendationEngine {
        RecommendationEngine(
            modelContainer: container,
            cacheStore: cacheStore ?? isolatedStore(),
            recalculationInterval: interval
        )
    }

    @Test func `recommends unwatched titles similar to a favorite and excludes watched ones`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0])
        makeMovie(container, id: "different", vector: [0, 0, 0, 1])
        makeMovie(container, id: "watched-similar", vector: [0.95, 0.05, 0, 0], watched: true)
        try container.mainContext.save()

        let engine = makeEngine(container)
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

        let engine = makeEngine(container)
        #expect(await engine.recommendations().isEmpty)
    }

    @Test func `downvoted titles are excluded`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0], vote: .downvote)
        try container.mainContext.save()

        let engine = makeEngine(container)
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

        let engine = makeEngine(container)
        let ids = await engine.recommendations().map(\.id)
        #expect(ids.first == "similar")
    }

    @Test func `reuses the cached list within the recalculation interval`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0])
        try container.mainContext.save()

        let store = isolatedStore()
        let first = await makeEngine(container, cacheStore: store).recommendations().map(\.id)
        #expect(first.contains("similar"))

        // A new, more-similar title appears after the first compute.
        makeMovie(container, id: "closer", vector: [0.99, 0.01, 0, 0])
        try container.mainContext.save()

        // Within the (default, day-long) interval the cached list is reused, so
        // the new title is not picked up.
        let second = await makeEngine(container, cacheStore: store).recommendations().map(\.id)
        #expect(second == first)
        #expect(!second.contains("closer"))
    }

    @Test func `recomputes once the interval has elapsed`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true)
        makeMovie(container, id: "similar", vector: [0.9, 0.1, 0, 0])
        try container.mainContext.save()

        let store = isolatedStore()
        _ = await makeEngine(container, cacheStore: store, interval: 0).recommendations()

        makeMovie(container, id: "closer", vector: [0.99, 0.01, 0, 0])
        try container.mainContext.save()

        // A zero interval forces a fresh rank every call, so the new title wins.
        let second = await makeEngine(container, cacheStore: store, interval: 0).recommendations().map(\.id)
        #expect(second.first == "closer")
    }

    // MARK: - Content Management visibility

    @Test func `candidates in an excluded category are never ranked`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true, category: "en")
        makeMovie(container, id: "hidden-closer", vector: [0.99, 0.01, 0, 0], category: "nl")
        makeMovie(container, id: "visible", vector: [0.9, 0.1, 0, 0], category: "en")
        try container.mainContext.save()

        let ids = await makeEngine(container).recommendations(excluding: ["nl"]).map(\.id)
        #expect(!ids.contains("hidden-closer"))
        #expect(ids.first == "visible")
    }

    @Test func `changing the excluded set invalidates the cached list`() async throws {
        let container = try makeTestContainer()
        makeMovie(container, id: "liked", vector: [1, 0, 0, 0], favorite: true, category: "en")
        makeMovie(container, id: "dutch", vector: [0.9, 0.1, 0, 0], category: "nl")
        try container.mainContext.save()

        let store = isolatedStore()
        let hidden = await makeEngine(container, cacheStore: store).recommendations(excluding: ["nl"]).map(\.id)
        #expect(!hidden.contains("dutch"))

        // Un-hiding must not wait out the (day-long) recalculation interval.
        let shown = await makeEngine(container, cacheStore: store).recommendations().map(\.id)
        #expect(shown.contains("dutch"))
    }

    @Test func `a cache written before visibility tracking is recomputed`() throws {
        let legacy = Data(#"{"computedAt": 0, "items": [{"id": "a", "kind": "movie"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(RecommendationCache.self, from: legacy)
        #expect(decoded.visibilityToken == nil)
        #expect(decoded.visibilityToken != ContentRestriction.visibilityToken(for: []))
    }

    @Test func `the visibility token is order independent and set specific`() {
        #expect(
            ContentRestriction.visibilityToken(for: ["a", "b"])
                == ContentRestriction.visibilityToken(for: ["b", "a"])
        )
        #expect(
            ContentRestriction.visibilityToken(for: ["a"])
                != ContentRestriction.visibilityToken(for: ["a", "b"])
        )
    }
}
