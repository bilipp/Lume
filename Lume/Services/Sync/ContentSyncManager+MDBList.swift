import Foundation
import SwiftData

// MARK: - MDBList Ratings Enrichment

extension ContentSyncManager {
    /// Fetches aggregator ratings (IMDb / Rotten Tomatoes / Metacritic / Trakt /
    /// Letterboxd / TMDB) for a TMDB id without persisting. The caller applies
    /// the data directly to its own context to avoid cross-context merge timing
    /// issues. Returns an empty array when MDBList is unconfigured or the title
    /// is unknown.
    func fetchMDBListRatings(tmdbId: Int, type: MDBListClient.MediaType) async throws -> [ExternalRating] {
        let client = MDBListClient.shared
        guard client.isConfigured else { return [] }
        return try await client.ratings(tmdbId: tmdbId, type: type)
    }

    /// Fetches and persists MDBList ratings for a movie **off the main thread**,
    /// on the engine actor's own background context (the save auto-merges into
    /// the main context). Keeps the rating write off a detail view's hot path.
    ///
    /// Fresh ratings on a sibling (same TMDB id) are copied instead of fetched,
    /// and fetched ratings are written to every sibling.
    func enrichMovieRatings(movieId: String, tmdbId: Int) async {
        let row = Movie.row(id:in:)
        let siblings = Movie.rows(sharing:except:in:)
        if copyRatingsFromSibling(of: movieId, tmdbId: tmdbId, row: row) { return }
        guard let ratings = try? await fetchMDBListRatings(tmdbId: tmdbId, type: .movie) else { return }
        writeRatings(ratings, to: movieId, tmdbId: tmdbId, row: row, siblings: siblings)
    }

    /// Series counterpart of ``enrichMovieRatings(movieId:tmdbId:)``.
    func enrichSeriesRatings(seriesId: String, tmdbId: Int) async {
        let row = Series.row(id:in:)
        let siblings = Series.rows(sharing:except:in:)
        if copyRatingsFromSibling(of: seriesId, tmdbId: tmdbId, row: row) { return }
        guard let ratings = try? await fetchMDBListRatings(tmdbId: tmdbId, type: .show) else { return }
        writeRatings(ratings, to: seriesId, tmdbId: tmdbId, row: row, siblings: siblings)
    }

    private func copyRatingsFromSibling<Row: EnrichedTitleRow>(
        of id: String,
        tmdbId: Int,
        row: (String, ModelContext) -> Row?
    ) -> Bool {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let target = row(id, context) else { return false }
        let latest = Row.latestSibling(sharing: tmdbId, except: id, by: .ratings, in: context)
        guard TitleEnrichmentSiblings.copyRatings(from: latest.map { [$0] } ?? [], to: target) else { return false }
        try? context.save()
        return true
    }

    private func writeRatings<Row: EnrichedTitleRow>(
        _ ratings: [ExternalRating],
        to id: String,
        tmdbId: Int,
        row: (String, ModelContext) -> Row?,
        siblings: (Int, String, ModelContext) -> [Row]
    ) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let target = row(id, context) else { return }
        TitleEnrichmentSiblings.applyRatings(ratings, to: target, siblings: siblings(tmdbId, id, context))
        try? context.save()
    }
}

// MARK: - Detail-screen enrichment

/// Fetches MDBList ratings for a movie and persists them, keyed directly by
/// the TMDB id we already store. No-ops when MDBList is unconfigured, the TMDB
/// id is missing, or the cache is still fresh. Call from a detail view's
/// `.task` after TMDB enrichment.
@MainActor
func enrichMovieRatingsIfNeeded(_ movie: Movie, context: ModelContext) async {
    guard let tmdbId = movie.tmdbId, MDBListClient.shared.isConfigured else { return }
    if let enrichedAt = movie.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < TitleEnrichmentSiblings.freshness { return }
    // Fetch + persist on the manager's background context (off the main thread);
    // the save auto-merges back so `movie.externalRatings` updates in the view.
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichMovieRatings(movieId: movie.id, tmdbId: tmdbId)
}

/// Series counterpart of ``enrichMovieRatingsIfNeeded(_:context:)``.
@MainActor
func enrichSeriesRatingsIfNeeded(_ series: Series, context: ModelContext) async {
    guard let tmdbId = series.tmdbId, MDBListClient.shared.isConfigured else { return }
    if let enrichedAt = series.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < TitleEnrichmentSiblings.freshness { return }
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichSeriesRatings(seriesId: series.id, tmdbId: tmdbId)
}
