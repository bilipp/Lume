//
//  EmbeddingSpaceStore.swift
//  Lume
//
//  Remembers which vector space the stored embeddings were produced in.
//
//  `TextEmbedder` has two backends and they are not interchangeable: a cosine
//  between a contextual vector and a sentence vector is meaningless, and both
//  happen to be 512-dimensional, so nothing about the blob itself gives the
//  mismatch away. If the backend ever changes under an existing store — a
//  device that indexed on an older build, a platform whose model support
//  changes — every recommendation silently becomes noise.
//
//  So the indexer stamps the space it used and, on a mismatch, drops the
//  embeddings it can no longer compare so the next pass rebuilds them. Cheap in
//  practice: the backend is a platform constant, so this fires at most once per
//  device, and re-embedding costs no TMDB traffic (the ids and enrichment are
//  already stored — see `ContentIndexer.resolve`).
//

import Foundation

nonisolated enum EmbeddingSpaceStore {
    private static let key = "contentIndex.embeddingSpaceID"

    /// The space the stored embeddings were produced in, or nil before the
    /// first pass ever completed a chunk.
    static func current(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func set(_ spaceID: String, in defaults: UserDefaults = .standard) {
        defaults.set(spaceID, forKey: key)
    }

    /// True when the stored embeddings came from a *different* backend and must
    /// be rebuilt. False on a first run: there is nothing stored to invalidate.
    static func needsReset(to spaceID: String, in defaults: UserDefaults = .standard) -> Bool {
        guard let stored = current(in: defaults) else { return false }
        return stored != spaceID
    }
}
