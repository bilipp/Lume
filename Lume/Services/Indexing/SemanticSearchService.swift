//
//  SemanticSearchService.swift
//  Lume
//
//  Ranks indexed movies and series by meaning, using the on-device
//  NLContextualEmbedding vectors ContentIndexer stores in `embeddingData`.
//  The query is embedded into the same vector space and compared against every
//  indexed title by cosine similarity, so a search like "heist movie in a
//  dream" surfaces Inception even though those words never appear in its title.
//
//  Runs as an actor off the main thread: embedding the query and scanning the
//  catalog are both done on a background ModelContext, mirroring ContentIndexer,
//  so typing stays smooth. When the embedding model can't load on this device
//  the service reports itself unavailable and SearchView falls back to plain
//  lexical matching.
//

import Accelerate
import Foundation
import OSLog
import SwiftData

actor SemanticSearchService {
    static let shared = SemanticSearchService()

    /// Minimum cosine similarity for a title to count as a semantic match.
    /// Below this the relationship to the query is too weak to be useful and
    /// only adds noise to the results.
    private let minimumSimilarity: Float = 0.35

    private var container: ModelContainer?
    /// The query embedder, created and loaded lazily on first search and reused
    /// across searches. Shares the model assets ContentIndexer downloads.
    private var embedder: TextEmbedder?
    /// nil until we first try to prepare the model; `false` once we know it
    /// can't load on this device, so we stop retrying for the session.
    private var modelAvailable: Bool?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Results

    /// A single ranked title: its persistent `id` and cosine score to the query.
    struct Match {
        let id: String
        let score: Float
    }

    /// Ranked ids per content type, most relevant first.
    struct Results {
        var movies: [Match] = []
        var series: [Match] = []
    }

    /// Ranks indexed movies/series by semantic similarity to `query`.
    ///
    /// Returns `nil` when semantic search is unavailable — the model can't load
    /// on this device, or the query produced no embedding — signalling the
    /// caller to rely on lexical matching alone. An empty `Results` means the
    /// search ran but nothing cleared the similarity threshold.
    func search(
        query: String,
        includeMovies: Bool,
        includeSeries: Bool,
        limit: Int
    ) async -> Results? {
        guard includeMovies || includeSeries, let container else { return nil }
        guard let embedder = await preparedEmbedder() else { return nil }
        guard let queryVector = try? embedder.vector(for: query) else { return nil }

        let normalizedQuery = normalized(queryVector)
        guard !normalizedQuery.isEmpty else { return nil }

        let context = ModelContext(container)
        var results = Results()
        if includeMovies {
            results.movies = rank(
                MovieEmbeddings(context: context).rows(),
                against: normalizedQuery,
                limit: limit
            )
        }
        if includeSeries {
            results.series = rank(
                SeriesEmbeddings(context: context).rows(),
                against: normalizedQuery,
                limit: limit
            )
        }
        return results
    }

    // MARK: - Embedder lifecycle

    /// Lazily loads the embedding model. Caches the result so a device without
    /// the model isn't asked to download it on every keystroke.
    private func preparedEmbedder() async -> TextEmbedder? {
        if let embedder { return embedder }
        if modelAvailable == false { return nil }

        do {
            let embedder = try TextEmbedder()
            try await embedder.prepare()
            self.embedder = embedder
            modelAvailable = true
            return embedder
        } catch {
            modelAvailable = false
            Logger.indexing.error("Semantic search unavailable; falling back to lexical search: \(error)")
            return nil
        }
    }

    // MARK: - Ranking

    /// Scores every candidate against the (already normalized) query vector and
    /// returns the strongest matches, highest score first.
    private func rank(
        _ rows: [(id: String, data: Data)],
        against normalizedQuery: [Float],
        limit: Int
    ) -> [Match] {
        var matches: [Match] = []
        matches.reserveCapacity(rows.count)
        for row in rows {
            let vector = TextEmbedder.decode(row.data)
            guard vector.count == normalizedQuery.count else { continue }
            let score = cosineToNormalized(normalizedQuery, vector)
            if score >= minimumSimilarity {
                matches.append(Match(id: row.id, score: score))
            }
        }
        matches.sort { $0.score > $1.score }
        return Array(matches.prefix(limit))
    }

    // MARK: - Vector math

    /// Returns `vector` scaled to unit length, or an empty array if it has no
    /// magnitude (so the caller can bail out instead of dividing by zero).
    private func normalized(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sqrt(sumOfSquares)
        guard magnitude > 0 else { return [] }
        var divisor = magnitude
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Cosine similarity of a unit-length `normalizedQuery` to an arbitrary
    /// `vector`: `dot(q, v) / |v|`. Equal counts are guaranteed by the caller.
    private func cosineToNormalized(_ normalizedQuery: [Float], _ vector: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(normalizedQuery, 1, vector, 1, &dot, vDSP_Length(vector.count))
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sqrt(sumOfSquares)
        guard magnitude > 0 else { return 0 }
        return dot / magnitude
    }
}

// MARK: - Embedding fetches

/// Snapshots the `(id, embeddingData)` of every indexed movie, leaving the rest
/// of each row unfaulted so a whole-catalog scan stays cheap.
private struct MovieEmbeddings {
    let context: ModelContext

    func rows() -> [(id: String, data: Data)] {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.embeddingData != nil })
        descriptor.propertiesToFetch = [\.id, \.embeddingData]
        let movies = (try? context.fetch(descriptor)) ?? []
        return movies.compactMap { movie in
            guard let data = movie.embeddingData else { return nil }
            return (movie.id, data)
        }
    }
}

/// Same as `MovieEmbeddings`, for series.
private struct SeriesEmbeddings {
    let context: ModelContext

    func rows() -> [(id: String, data: Data)] {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.embeddingData != nil })
        descriptor.propertiesToFetch = [\.id, \.embeddingData]
        let series = (try? context.fetch(descriptor)) ?? []
        return series.compactMap { item in
            guard let data = item.embeddingData else { return nil }
            return (item.id, data)
        }
    }
}
