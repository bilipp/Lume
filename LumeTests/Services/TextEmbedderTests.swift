//
//  TextEmbedderTests.swift
//  LumeTests
//
//  Covers the two-backend embedder and the vector-space bookkeeping that keeps
//  the recommendation engine from comparing vectors it cannot compare.
//
//  The tests run on the iOS simulator only (see CLAUDE.md), so the tvOS branch
//  of `TextEmbedder.preferred()` cannot be exercised here — what *is* covered is
//  everything the tvOS path depends on: that the sentence backend loads with no
//  assets and no network, that it produces usable vectors, that it is stamped
//  with its own space id, and that a space change invalidates the store.
//

import Foundation
@testable import Lume
import Testing

struct TextEmbedderTests {
    // MARK: - Backends

    @Test func `sentence backend needs no assets and no prepare`() async throws {
        let embedder = try TextEmbedder.sentence()
        // Must not hang, throw or reach the network — this is the whole point
        // of the backend on tvOS, where contextual assets are never served.
        try await embedder.prepare()
        let embedded = try embedder.vector(for: "Inception (2010). Action, Science Fiction.")
        let vector = try #require(embedded)
        #expect(vector.count > 0)
        #expect(vector.contains { $0 != 0 })
    }

    @Test func `sentence backend separates genres in short documents`() throws {
        let embedder = try TextEmbedder.sentence()
        func vector(_ text: String) throws -> [Float] {
            let vector = try embedder.vector(for: text)
            return try #require(vector)
        }
        let nemo = try vector("Finding Nemo (2003). Animation, Family, Adventure.")
        let toyStory = try vector("Toy Story (1995). Animation, Family, Adventure.")
        let godfather = try vector("The Godfather (1972). Crime, Drama.")

        // Same genre must sit closer than a different one, measured with the
        // very function "For You" ranks on. If this inverts, the backend is
        // useless and the row fills with noise.
        #expect(RecommendationScoring.cosineSimilarity(nemo, toyStory)
            > RecommendationScoring.cosineSimilarity(nemo, godfather))
    }

    @Test func `sentence backend prefers short documents`() throws {
        #expect(try TextEmbedder.sentence().prefersShortDocuments)
    }

    @Test func `backends occupy different vector spaces`() throws {
        let sentence = try TextEmbedder.sentence()
        // Not available on every host; skip rather than fail when it isn't.
        guard let contextual = try? TextEmbedder.contextual() else { return }
        #expect(sentence.spaceID != contextual.spaceID)
        #expect(!contextual.prefersShortDocuments)
    }

    @Test func `unload is safe on a backend that was never prepared`() throws {
        try TextEmbedder.sentence().unload()
        try TextEmbedder.sentence().unload()
    }

    // MARK: - Space bookkeeping

    @Test func `first run has nothing to invalidate`() throws {
        let defaults = try makeDefaults()
        #expect(EmbeddingSpaceStore.current(in: defaults) == nil)
        #expect(!EmbeddingSpaceStore.needsReset(to: "sentence-en-512", in: defaults))
    }

    @Test func `same space needs no reset`() throws {
        let defaults = try makeDefaults()
        EmbeddingSpaceStore.set("sentence-en-512", in: defaults)
        #expect(!EmbeddingSpaceStore.needsReset(to: "sentence-en-512", in: defaults))
    }

    @Test func `changed space needs a reset`() throws {
        let defaults = try makeDefaults()
        EmbeddingSpaceStore.set("sentence-en-512", in: defaults)
        #expect(EmbeddingSpaceStore.needsReset(to: "contextual-ABC", in: defaults))

        EmbeddingSpaceStore.set("contextual-ABC", in: defaults)
        #expect(!EmbeddingSpaceStore.needsReset(to: "contextual-ABC", in: defaults))
        #expect(EmbeddingSpaceStore.current(in: defaults) == "contextual-ABC")
    }

    // MARK: - Helpers

    /// A private suite so the tests never touch (or race on) the app's
    /// `UserDefaults.standard`.
    private func makeDefaults() throws -> UserDefaults {
        let name = "TextEmbedderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
