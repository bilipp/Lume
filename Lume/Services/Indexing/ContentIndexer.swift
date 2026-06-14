//
//  ContentIndexer.swift
//  Lume
//
//  Builds the local content index: resolves each movie and series against
//  TMDB (searching by cleaned title when the provider supplies no id), applies
//  the same enrichment the detail screens use, and stores an on-device
//  embedding vector for future semantic search.
//
//  Designed to run slowly in the background: items are processed in small
//  chunks on a dedicated ModelContext with pauses in between, so neither TMDB
//  nor the main thread is hammered. The loop waits while a playlist sync is
//  running and while the player is up — even a background-context save forces
//  the main context to merge and re-run every @Query, which hitches KSPlayer.
//

import Foundation
import OSLog
import SwiftData

actor ContentIndexer {
    private let modelContainer: ModelContainer
    private let tmdbClient: TMDBClient

    /// Items per chunk; the context is saved and progress published once per
    /// chunk so main-context merges stay infrequent.
    private let chunkSize = 50
    /// Pause between items — keeps TMDB traffic to a couple of requests per
    /// second at most.
    private let itemPause: Duration = .milliseconds(100)
    /// Pause before re-checking when a sync or playback blocks indexing.
    private let busyPause: Duration = .seconds(20)
    /// First wait before retrying a failed embedding-asset download; doubles
    /// each attempt up to `assetRetryMaxPause`. The OTA asset request times out
    /// on slow connections, so we back off and retry in-pass instead of ending
    /// the run (which would stall indexing until the next launch or sync).
    private let assetRetryPause: Duration = .seconds(15)
    private let assetRetryMaxPause: Duration = .seconds(300)

    init(modelContainer: ModelContainer, tmdbClient: TMDBClient = .shared) {
        self.modelContainer = modelContainer
        self.tmdbClient = tmdbClient
    }

    // MARK: - Run loop

    /// Indexes every unindexed title, publishing progress to `status`.
    /// Returns when the library is fully indexed; throws on cancellation, on
    /// an unavailable embedding model, or on a transient network failure (the
    /// next kick retries — already-indexed items are never reprocessed).
    func run(status: ContentIndexingService) async throws {
        var counts = try currentCounts()
        await status.update(indexed: counts.indexed, total: counts.total)
        guard counts.indexed < counts.total else {
            await status.finish(indexed: counts.indexed, total: counts.total)
            return
        }

        await status.setPreparing()
        let embedder = try TextEmbedder()
        try await prepareEmbedder(embedder, status: status)

        while !Task.isCancelled {
            if try await hasActiveSync() || (status.isPlaybackActive) {
                await status.setWaiting()
                try await Task.sleep(for: busyPause)
                continue
            }

            counts = try currentCounts()
            await status.update(indexed: counts.indexed, total: counts.total)

            let processed = try await indexNextChunk(embedder: embedder)
            if processed == 0 { break }
            try await Task.sleep(for: itemPause)
        }

        try Task.checkCancellation()
        counts = try currentCounts()
        await status.finish(indexed: counts.indexed, total: counts.total)
        Logger.indexing.info("Content index complete: \(counts.indexed) of \(counts.total) titles")
    }

    /// Loads the embedding model, waiting and retrying when its assets fail to
    /// download. The on-device asset request times out on slow connections;
    /// rather than abandoning the pass (which leaves indexing stalled until the
    /// next launch or sync) we back off and try again — the download usually
    /// succeeds on a later attempt. A model that genuinely has no assets for
    /// this device throws `EmbedderError`, which ends the run for good.
    private func prepareEmbedder(_ embedder: TextEmbedder, status: ContentIndexingService) async throws {
        var pause = assetRetryPause
        while true {
            try Task.checkCancellation()
            do {
                try await embedder.prepare()
                return
            } catch let error as TextEmbedder.EmbedderError {
                throw error
            } catch {
                let seconds = pause.components.seconds
                Logger.indexing.warning("Embedding asset download failed, retrying in \(seconds)s: \(error)")
                await status.setWaiting()
                try await Task.sleep(for: pause)
                pause = min(pause * 2, assetRetryMaxPause)
                await status.setPreparing()
            }
        }
    }

    // MARK: - Chunk processing

    /// Indexes up to `chunkSize` pending titles (movies first, then series) on
    /// a fresh context and saves once. Returns the number processed; 0 means
    /// the index is complete. Work already done in the chunk is saved even
    /// when an item throws, so a transient failure never loses progress.
    private func indexNextChunk(embedder: TextEmbedder) async throws -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        var movieDescriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.indexedAt == nil })
        movieDescriptor.fetchLimit = chunkSize
        let movies = try context.fetch(movieDescriptor)

        var seriesDescriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.indexedAt == nil })
        seriesDescriptor.fetchLimit = chunkSize - movies.count
        let series = movies.count < chunkSize ? try context.fetch(seriesDescriptor) : []

        var processed = 0
        do {
            for movie in movies {
                try Task.checkCancellation()
                try await index(movie: movie, context: context, embedder: embedder)
                processed += 1
                try await Task.sleep(for: itemPause)
            }
            for item in series {
                try Task.checkCancellation()
                try await index(series: item, context: context, embedder: embedder)
                processed += 1
                try await Task.sleep(for: itemPause)
            }
        } catch {
            try? context.save()
            throw error
        }

        if processed > 0 {
            try context.save()
        }
        return processed
    }

    private func index(movie: Movie, context: ModelContext, embedder: TextEmbedder) async throws {
        let query = ContentIndexText.searchQuery(for: movie.name)

        if tmdbClient.isConfigured {
            if movie.tmdbId == nil {
                let year = ContentIndexText.year(fromReleaseDate: movie.releaseDate) ?? query.year
                movie.tmdbId = try await skippingPermanentFailures {
                    try await self.searchMovieID(query: query.title, year: year)
                }
            }
            if movie.tmdbEnrichedAt == nil, let tmdbId = movie.tmdbId {
                let details = try await skippingPermanentFailures {
                    try await self.tmdbClient.movieDetails(tmdbId)
                }
                if let details {
                    // Background context: skip the cast relationship — see
                    // applyMovieDetails. The embedding uses `movie.actors`, and
                    // the detail view fully enriches (incl. cast) on first open.
                    applyMovieDetails(details, to: movie, context: context, includeCast: false)
                }
            }
        }

        let document = ContentIndexText.document(for: .init(
            name: query.title,
            year: ContentIndexText.year(fromReleaseDate: movie.releaseDate) ?? query.year,
            genre: movie.genre,
            tagline: movie.tagline,
            plot: movie.plot,
            cast: movie.actors
        ))
        if let vector = try? embedder.vector(for: document) {
            movie.embeddingData = TextEmbedder.encode(vector)
        }
        movie.indexedAt = Date()
    }

    private func index(series: Series, context: ModelContext, embedder: TextEmbedder) async throws {
        let query = ContentIndexText.searchQuery(for: series.name)

        if tmdbClient.isConfigured {
            if series.tmdbId == nil {
                let year = ContentIndexText.year(fromReleaseDate: series.releaseDate) ?? query.year
                series.tmdbId = try await skippingPermanentFailures {
                    try await self.searchTVID(query: query.title, year: year)
                }
            }
            if series.tmdbEnrichedAt == nil, let tmdbId = series.tmdbId {
                let details = try await skippingPermanentFailures {
                    try await self.tmdbClient.tvDetails(tmdbId)
                }
                if let details {
                    // Background context: skip the cast relationship — see
                    // applySeriesDetails. The embedding uses the `series.cast`
                    // string; the detail view fully enriches (incl. cast) later.
                    applySeriesDetails(details, to: series, context: context, includeCast: false)
                }
            }
        }

        let document = ContentIndexText.document(for: .init(
            name: query.title,
            year: ContentIndexText.year(fromReleaseDate: series.releaseDate) ?? query.year,
            genre: series.genre,
            tagline: series.tagline,
            plot: series.plot,
            cast: series.cast
        ))
        if let vector = try? embedder.vector(for: document) {
            series.embeddingData = TextEmbedder.encode(vector)
        }
        series.indexedAt = Date()
    }

    // MARK: - TMDB search with year fallback

    /// Provider year tags are often wrong, so a year-constrained search that
    /// finds nothing is retried without the year.
    private func searchMovieID(query: String, year: Int?) async throws -> Int? {
        if let id = try await tmdbClient.searchMovieID(query: query, year: year) {
            return id
        }
        guard year != nil else { return nil }
        return try await tmdbClient.searchMovieID(query: query, year: nil)
    }

    private func searchTVID(query: String, year: Int?) async throws -> Int? {
        if let id = try await tmdbClient.searchTVID(query: query, year: year) {
            return id
        }
        guard year != nil else { return nil }
        return try await tmdbClient.searchTVID(query: query, year: nil)
    }

    /// Runs a TMDB request, converting *permanent* failures (no match, bad
    /// payload) into nil so the item proceeds without TMDB data. Transient
    /// failures (offline, 5xx, rate limit) rethrow and end the run — the next
    /// kick retries those items.
    private func skippingPermanentFailures<T>(_ request: () async throws -> T?) async throws -> T? {
        do {
            return try await request()
        } catch let error as TMDBError {
            switch error {
            case let .serverError(code) where code == 404:
                return nil
            case .decodingError, .invalidURL, .missingToken:
                return nil
            case .serverError, .invalidResponse:
                throw error
            }
        }
    }

    // MARK: - Store queries

    private func currentCounts() throws -> (indexed: Int, total: Int) {
        let context = ModelContext(modelContainer)
        let totalMovies = try context.fetchCount(FetchDescriptor<Movie>())
        let totalSeries = try context.fetchCount(FetchDescriptor<Series>())
        let indexedMovies = try context.fetchCount(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.indexedAt != nil })
        )
        let indexedSeries = try context.fetchCount(
            FetchDescriptor<Series>(predicate: #Predicate { $0.indexedAt != nil })
        )
        return (indexedMovies + indexedSeries, totalMovies + totalSeries)
    }

    private func hasActiveSync() throws -> Bool {
        let context = ModelContext(modelContainer)
        let syncing = SyncStatus.syncing.rawValue
        return try context.fetchCount(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.syncStatusRaw == syncing })
        ) > 0
    }
}
