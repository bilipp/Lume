//
//  TextEmbedder.swift
//  Lume
//
//  Turns index documents into fixed-size vectors for the on-device
//  recommendation engine (and future semantic search).
//
//  Two backends, because the good one isn't available on every platform:
//
//  • `NLContextualEmbedding` (transformer, 512-dim, multilingual) is the
//    preferred model. Its assets download over the air on first use.
//  • `NLEmbedding.sentenceEmbedding(for: .english)` is the tvOS backend:
//    bundled with the OS, nothing to download, but much coarser — it only
//    separates titles when the document is SHORT, which is what
//    `prefersShortDocuments` is for.
//
//  **tvOS serves no contextual assets.** Measured on tvOS 26.5:
//  `NLContextualEmbedding(script: .latin)` constructs fine, but
//  `hasAvailableAssets` is false and `requestAssets` never calls its completion
//  handler — not an error, not a timeout, nothing. The old code awaited that
//  handler, so every Apple TV sat in `.preparing` forever, indexed zero titles
//  and left "For You" permanently empty. The backend is therefore chosen at
//  compile time on tvOS rather than discovered at runtime.
//
//  `requestAssets` is still wrapped in a timeout on the other platforms: a call
//  that never returns would wedge the pass the same way, and the caller's
//  retry/backoff handles a genuinely slow download.
//
//  Backends produce vectors in *different, incomparable* spaces, so each one
//  publishes a `spaceID` and `ContentIndexer` re-embeds the catalog whenever it
//  changes.
//

import Foundation
import NaturalLanguage
import os

final nonisolated class TextEmbedder {
    enum EmbedderError: Error {
        /// No embedding model of any kind exists for this device.
        case modelUnavailable
        /// Model assets are not on-device and could not be downloaded.
        case assetsUnavailable
        /// The asset request never came back — see the type comment.
        case assetRequestTimedOut
    }

    private enum Backend {
        case contextual(NLContextualEmbedding)
        case sentence(NLEmbedding)
    }

    /// How long to wait for `requestAssets` before giving up on this attempt.
    /// The caller retries with backoff, so this only has to be longer than a
    /// realistic download, not longer than the worst connection.
    private static let assetRequestTimeout: Duration = .seconds(120)

    private let backend: Backend

    /// Identifies the vector space this embedder produces. Vectors from two
    /// different spaces are not comparable, so `ContentIndexer` stores this
    /// alongside the index and re-embeds the catalog when it changes.
    let spaceID: String

    /// True when long documents degrade the vector, so the indexer should embed
    /// `ContentIndexText.shortDocument` instead of the full one.
    ///
    /// Measured on tvOS 26.5 over 8 titles in 4 genre pairs, as the gap between
    /// the mean same-genre and mean cross-genre cosine: `title (year). genre.`
    /// scores 0.118, the full `+ tagline + plot + cast` document 0.003 — i.e.
    /// the long document is pure noise through this model. (The contextual
    /// model has no such problem, which is why this is per-backend.)
    let prefersShortDocuments: Bool

    private init(backend: Backend) {
        self.backend = backend
        switch backend {
        case let .contextual(embedding):
            spaceID = "contextual-\(embedding.modelIdentifier)"
            prefersShortDocuments = false
        case let .sentence(embedding):
            spaceID = "sentence-en-\(embedding.dimension)"
            prefersShortDocuments = true
        }
    }

    /// The embedder to index with on this platform.
    ///
    /// tvOS gets the sentence model outright — see the type comment: the
    /// contextual model's assets are never served there and asking for them
    /// hangs. Everywhere else the contextual model is the only choice, so that
    /// one device can never end up with a catalog embedded half in each space.
    static func preferred() throws -> TextEmbedder {
        #if os(tvOS)
            try sentence()
        #else
            try contextual()
        #endif
    }

    /// The contextual (preferred) embedder. The Latin-script model covers every
    /// language the app localizes to plus most other European ones in one shared
    /// vector space. `prepare()` must succeed before `vector(for:)`.
    static func contextual() throws -> TextEmbedder {
        guard let embedding = NLContextualEmbedding(script: .latin) else {
            throw EmbedderError.modelUnavailable
        }
        return TextEmbedder(backend: .contextual(embedding))
    }

    /// The bundled English sentence embedder. Needs no `prepare()` work, no
    /// network and no assets — but see `prefersShortDocuments`.
    ///
    /// English-only in name, and that matters less than it sounds for the short
    /// document: measured on tvOS 26.5, German `title (year). genre.` documents
    /// separate at a 0.097 margin against 0.118 for the same titles in English,
    /// because the genre words carry the signal and most are cognates. Not worth
    /// a second, English-language TMDB fetch per title (which would also
    /// overwrite the localized genre the user sees).
    static func sentence() throws -> TextEmbedder {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbedderError.modelUnavailable
        }
        return TextEmbedder(backend: .sentence(embedding))
    }

    /// Downloads the model assets if needed and loads the model into memory.
    func prepare() async throws {
        guard case let .contextual(embedding) = backend else { return }
        if !embedding.hasAvailableAssets {
            let result = try await Self.requestAssets(for: embedding)
            guard result == .available else {
                throw EmbedderError.assetsUnavailable
            }
        }
        try embedding.load()
    }

    /// `requestAssets`, bounded by `assetRequestTimeout`. Deliberately not a
    /// task group racing a sleep: cancelling a group waits for its children, and
    /// the child awaiting a completion handler that never fires would never
    /// finish — reintroducing the exact hang this guards against.
    private static func requestAssets(
        for embedding: NLContextualEmbedding
    ) async throws -> NLContextualEmbedding.AssetsResult {
        let hasResumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            /// Resumes at most once, whichever of the two paths gets there first.
            func finish(_ body: () -> Void) {
                let first = hasResumed.withLock { resumed -> Bool in
                    defer { resumed = true }
                    return !resumed
                }
                if first { body() }
            }

            embedding.requestAssets { result, error in
                finish {
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Double(assetRequestTimeout.components.seconds)
            ) {
                finish { continuation.resume(throwing: EmbedderError.assetRequestTimedOut) }
            }
        }
    }

    /// Frees the loaded model from memory. The contextual model is tens of MB
    /// resident; call this when an indexing pass ends so it isn't left loaded
    /// between passes (and while the app sits in the background as a jetsam
    /// target). Idempotent and safe whether or not `prepare()` loaded a model.
    func unload() {
        if case let .contextual(embedding) = backend {
            embedding.unload()
        }
    }

    /// Mean-pooled sentence vector for `text`. Returns nil when the model
    /// produces no tokens (e.g. empty input).
    func vector(for text: String) throws -> [Float]? {
        switch backend {
        case let .contextual(embedding):
            let result = try embedding.embeddingResult(for: text, language: nil)
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count {
                    sum[index] += value
                }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { return nil }
            return sum.map { Float($0 / Double(tokenCount)) }

        case let .sentence(embedding):
            guard let vector = embedding.vector(for: text) else { return nil }
            return vector.map(Float.init)
        }
    }

    // MARK: - Vector blob coding

    /// Encodes a vector as the raw Float32 blob stored in
    /// `Movie.embeddingData` / `Series.embeddingData`.
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        return [Float](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            _ = data.copyBytes(to: buffer)
            initializedCount = count
        }
    }
}
