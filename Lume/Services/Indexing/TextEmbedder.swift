//
//  TextEmbedder.swift
//  Lume
//
//  Wraps NLContextualEmbedding to turn index documents into fixed-size
//  vectors for on-device semantic search. The model assets download
//  over-the-air on first use; `prepare()` must succeed before `vector(for:)`.
//

import Foundation
import NaturalLanguage

final nonisolated class TextEmbedder {
    enum EmbedderError: Error {
        /// No contextual embedding model exists for the script on this device.
        case modelUnavailable
        /// Model assets are not on-device and could not be downloaded.
        case assetsUnavailable
    }

    private let embedding: NLContextualEmbedding

    /// The Latin-script model covers all languages the app localizes to
    /// (English, German) plus most other European languages in one shared
    /// vector space, so documents and future search queries stay comparable.
    init() throws {
        guard let embedding = NLContextualEmbedding(script: .latin) else {
            throw EmbedderError.modelUnavailable
        }
        self.embedding = embedding
    }

    /// Downloads the model assets if needed and loads the model into memory.
    func prepare() async throws {
        if !embedding.hasAvailableAssets {
            let result = try await embedding.requestAssets()
            guard result == .available else {
                throw EmbedderError.assetsUnavailable
            }
        }
        try embedding.load()
    }

    /// Mean-pooled sentence vector for `text`. Returns nil when the model
    /// produces no tokens (e.g. empty input).
    func vector(for text: String) throws -> [Float]? {
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
