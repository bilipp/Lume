//
//  ContentIndexer+Write.swift
//  Lume
//
//  The write phase of an index chunk: what one title resolved against TMDB is
//  written to it and to every pending sibling row of the same title (other
//  qualities, languages, playlists), so duplicates cost no TMDB traffic of
//  their own.
//

import Foundation
import SwiftData

/// The columns the indexer writes, shared by movies and series.
nonisolated protocol IndexedTitleRow: TitleGroupedRow {
    var tmdbId: Int? { get set }
    var tmdbEnrichedAt: Date? { get }
    var releaseDate: String? { get }
    var genre: String? { get }
    var tagline: String? { get }
    var plot: String? { get }
    var embeddingData: Data? { get set }
    /// The cast names the embedding document reads.
    var indexCast: String? { get }
    func assignTitleGroupKey()
}

nonisolated extension Movie: IndexedTitleRow {
    var indexCast: String? {
        actors
    }

    func assignTitleGroupKey() {
        TitleGroupPrimaries.assignKey(to: self)
    }
}

nonisolated extension Series: IndexedTitleRow {
    var indexCast: String? {
        cast
    }

    func assignTitleGroupKey() {
        TitleGroupPrimaries.assignKey(to: self)
    }
}

nonisolated extension ContentIndexer {
    /// State one chunk's write phase shares across its titles.
    struct WriteBatch {
        let context: ModelContext
        let embedder: TextEmbedder?
        let hiddenCategoryIDs: Set<String>
        /// The (category, key) groups whose key changed, for the primary
        /// re-election before the chunk's save.
        var touched = TitleGroupPrimaries.Touched()
        /// Vectors already computed this chunk, by document: siblings of one
        /// title usually embed the same text.
        var vectors: [String: Data] = [:]

        func isHidden(_ row: some TitleGroupedRow) -> Bool {
            row.categoryId.map(hiddenCategoryIDs.contains) ?? false
        }

        mutating func embedding(for facts: ContentIndexText.TitleFacts) -> Data? {
            guard let embedder else { return nil }
            let document = ContentIndexer.document(for: facts, embedder: embedder)
            if let cached = vectors[document] { return cached }
            guard let vector = try? embedder.vector(for: document) else { return nil }
            let data = TextEmbedder.encode(vector)
            vectors[document] = data
            return data
        }
    }

    /// The cleaned title TMDB is searched with, and the year: the release
    /// date's when it holds one, else the year tagged in the provider name.
    static func searchQuery(name: String, releaseDate: String?) -> (title: String, year: Int?) {
        let query = ContentIndexText.searchQuery(for: name)
        return (query.title, ContentIndexText.year(fromReleaseDate: releaseDate) ?? query.year)
    }

    /// Re-fetches the title on the write context and applies the resolved TMDB
    /// data, embedding and index stamp to it and to every pending sibling: rows
    /// with the same TMDB id, or — for a title that had none — the same
    /// `titleGroupKey`. Synchronous: the objects are realised and mutated while
    /// the store is open, never across an `await`. A title that vanished since
    /// Phase 1 (deleted by a sync), one a sibling already stamped this chunk,
    /// and one whose category was hidden in the meantime are skipped — a hidden
    /// title stays unindexed until unhidden.
    static func write(_ result: IndexResult, batch: inout WriteBatch) {
        switch result.item.kind {
        case .movie:
            for row in movieRows(for: result, in: batch) {
                stamp(row, with: result, batch: &batch, touched: \.movies) { details, context in
                    // Background context: skip the cast relationship — see
                    // applyMovieDetails. The detail view fully enriches
                    // (incl. cast) on first open.
                    applyMovieDetails(details, to: row, context: context, includeCast: false)
                }
            }
        case .series:
            for row in seriesRows(for: result, in: batch) {
                stamp(row, with: result, batch: &batch, touched: \.series) { details, context in
                    applySeriesDetails(details, to: row, context: context, includeCast: false)
                }
            }
        }
    }

    /// The document to embed for a title, in the shape this embedder's backend
    /// can actually use. The coarse sentence backend (tvOS) drowns in a full
    /// plot + cast document — see `TextEmbedder.prefersShortDocuments`.
    static func document(for facts: ContentIndexText.TitleFacts, embedder: TextEmbedder) -> String {
        embedder.prefersShortDocuments
            ? ContentIndexText.shortDocument(for: facts)
            : ContentIndexText.document(for: facts)
    }
}

private nonisolated extension ContentIndexer {
    static func movieRows(for result: IndexResult, in batch: WriteBatch) -> [Movie] {
        let id = result.item.id
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? batch.context.fetch(descriptor).first else { return [] }
        var rows = [movie]
        if let tmdbId = result.resolvedTMDBId {
            let value: Int? = tmdbId
            rows += (try? batch.context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
                $0.indexedAt == nil && $0.tmdbId == value && $0.id != id
            }))) ?? []
        }
        if let key = result.item.groupKey, result.item.existingTMDBId == nil {
            let value: String? = key
            rows += (try? batch.context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
                $0.indexedAt == nil && $0.tmdbId == nil && $0.titleGroupKey == value && $0.id != id
            }))) ?? []
        }
        return pending(rows, primary: movie, in: batch)
    }

    static func seriesRows(for result: IndexResult, in batch: WriteBatch) -> [Series] {
        let id = result.item.id
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let series = try? batch.context.fetch(descriptor).first else { return [] }
        var rows = [series]
        if let tmdbId = result.resolvedTMDBId {
            let value: Int? = tmdbId
            rows += (try? batch.context.fetch(FetchDescriptor<Series>(predicate: #Predicate {
                $0.indexedAt == nil && $0.tmdbId == value && $0.id != id
            }))) ?? []
        }
        if let key = result.item.groupKey, result.item.existingTMDBId == nil {
            let value: String? = key
            rows += (try? batch.context.fetch(FetchDescriptor<Series>(predicate: #Predicate {
                $0.indexedAt == nil && $0.tmdbId == nil && $0.titleGroupKey == value && $0.id != id
            }))) ?? []
        }
        return pending(rows, primary: series, in: batch)
    }

    /// The rows still to write: none when the title itself was already stamped
    /// by a sibling this chunk or is hidden, else each unstamped, visible row
    /// once. The fetches can return rows this chunk already stamped in memory.
    static func pending<Row: IndexedTitleRow>(_ rows: [Row], primary: Row, in batch: WriteBatch) -> [Row] {
        guard primary.indexedAt == nil, !batch.isHidden(primary) else { return [] }
        var seen = Set<String>()
        return rows.filter { $0.indexedAt == nil && !batch.isHidden($0) && seen.insert($0.id).inserted }
    }

    static func stamp(
        _ row: some IndexedTitleRow,
        with result: IndexResult,
        batch: inout WriteBatch,
        touched: WritableKeyPath<TitleGroupPrimaries.Touched, Set<TitleGroupPrimaries.CategoryKey>>,
        applyDetails: (TMDBTitleDetails, ModelContext) -> Void
    ) {
        TitleGroupPrimaries.track(row, into: &batch.touched[keyPath: touched]) {
            if row.tmdbId == nil, let tmdbId = result.resolvedTMDBId {
                row.tmdbId = tmdbId
            }
            // A row still without an id keeps its title key; re-deriving it
            // would only parse the name again.
            if row.tmdbId != nil {
                row.assignTitleGroupKey()
            }
        }
        if let details = result.details, row.tmdbEnrichedAt == nil, row.tmdbId == result.resolvedTMDBId {
            applyDetails(details, batch.context)
        }
        let query = row.id == result.item.id
            ? (title: result.item.title, year: result.item.year)
            : searchQuery(name: row.name, releaseDate: row.releaseDate)
        if let data = batch.embedding(for: .init(
            name: query.title,
            year: query.year,
            genre: row.genre,
            tagline: row.tagline,
            plot: row.plot,
            cast: row.indexCast
        )) {
            row.embeddingData = data
        }
        row.indexedAt = Date()
    }
}
