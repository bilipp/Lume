import Foundation
import SwiftData

// MARK: - OMDb Ratings Enrichment

extension ContentSyncManager {
    /// Fetches aggregator ratings (IMDb / Rotten Tomatoes / Metacritic) for an
    /// IMDb id without persisting. The caller applies the data directly to its
    /// own context to avoid cross-context merge timing issues. Returns an empty
    /// array when OMDb is unconfigured or the title is unknown.
    func fetchOMDBRatings(imdbId: String) async throws -> [ExternalRating] {
        let client = OMDBClient.shared
        guard client.isConfigured else { return [] }
        return try await client.ratings(imdbId: imdbId)
    }

    /// Fetches and persists OMDb ratings for a movie **off the main thread**, on
    /// the engine actor's own background context (the save auto-merges into the
    /// main context). Keeps the rating write off a detail view's hot path.
    func enrichMovieRatings(movieId: String, imdbId: String) async {
        guard let ratings = try? await fetchOMDBRatings(imdbId: imdbId) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        descriptor.fetchLimit = 1
        guard let movie = try? context.fetch(descriptor).first else { return }
        movie.externalRatings = ratings
        movie.ratingsEnrichedAt = Date()
        try? context.save()
    }

    /// Series counterpart of ``enrichMovieRatings(movieId:imdbId:)``.
    func enrichSeriesRatings(seriesId: String, imdbId: String) async {
        guard let ratings = try? await fetchOMDBRatings(imdbId: imdbId) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        descriptor.fetchLimit = 1
        guard let series = try? context.fetch(descriptor).first else { return }
        series.externalRatings = ratings
        series.ratingsEnrichedAt = Date()
        try? context.save()
    }
}

// MARK: - Detail-screen enrichment

/// 14 days — ratings rarely move, so revisits within the window skip the fetch.
private let ratingsCacheWindow: TimeInterval = 14 * 24 * 3600

/// Fetches OMDb ratings for a movie and persists them, once its IMDb id is
/// known (resolved by TMDB enrichment). No-ops when OMDb is unconfigured, the
/// IMDb id is missing, or the cache is still fresh. Call from a detail view's
/// `.task` after TMDB enrichment.
@MainActor
func enrichMovieRatingsIfNeeded(_ movie: Movie, context: ModelContext) async {
    guard let imdbId = movie.imdbId, !imdbId.isEmpty, OMDBClient.shared.isConfigured else { return }
    if let enrichedAt = movie.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < ratingsCacheWindow { return }
    // Fetch + persist on the manager's background context (off the main thread);
    // the save auto-merges back so `movie.externalRatings` updates in the view.
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichMovieRatings(movieId: movie.id, imdbId: imdbId)
}

/// Series counterpart of ``enrichMovieRatingsIfNeeded(_:context:)``.
@MainActor
func enrichSeriesRatingsIfNeeded(_ series: Series, context: ModelContext) async {
    guard let imdbId = series.imdbId, !imdbId.isEmpty, OMDBClient.shared.isConfigured else { return }
    if let enrichedAt = series.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < ratingsCacheWindow { return }
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichSeriesRatings(seriesId: series.id, imdbId: imdbId)
}
