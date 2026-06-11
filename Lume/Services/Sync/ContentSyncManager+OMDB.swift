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
    let manager = ContentSyncManager(modelContainer: context.container)
    guard let ratings = try? await manager.fetchOMDBRatings(imdbId: imdbId) else { return }
    movie.externalRatings = ratings
    movie.ratingsEnrichedAt = Date()
    try? context.save()
}

/// Series counterpart of ``enrichMovieRatingsIfNeeded(_:context:)``.
@MainActor
func enrichSeriesRatingsIfNeeded(_ series: Series, context: ModelContext) async {
    guard let imdbId = series.imdbId, !imdbId.isEmpty, OMDBClient.shared.isConfigured else { return }
    if let enrichedAt = series.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < ratingsCacheWindow { return }
    let manager = ContentSyncManager(modelContainer: context.container)
    guard let ratings = try? await manager.fetchOMDBRatings(imdbId: imdbId) else { return }
    series.externalRatings = ratings
    series.ratingsEnrichedAt = Date()
    try? context.save()
}
