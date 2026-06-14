import Foundation
import SwiftData

// MARK: - TMDB Enrichment

extension ContentSyncManager {
    /// Fetches TMDB movie details without persisting. The caller applies
    /// the data directly to its own context to avoid cross-context merge
    /// timing issues.
    func fetchTMDBMovieDetails(tmdbId: Int) async throws -> TMDBTitleDetails? {
        let client = TMDBClient.shared
        guard client.isConfigured else { return nil }
        return try await client.movieDetails(tmdbId)
    }

    /// Fetches TMDB TV series details without persisting.
    func fetchTMDBTVDetails(tmdbId: Int) async throws -> TMDBTitleDetails? {
        let client = TMDBClient.shared
        guard client.isConfigured else { return nil }
        return try await client.tvDetails(tmdbId)
    }

    /// Fetches the list of TMDB movie IDs that belong to a collection.
    func fetchTMDBCollectionMovieIDs(collectionId: Int) async throws -> [Int] {
        let client = TMDBClient.shared
        guard client.isConfigured else { return [] }
        return try await client.collectionMovieIDs(collectionId)
    }
}

// MARK: - Direct context apply

/// Applies TMDB movie details directly to the given movie on the caller's
/// context — the detail views' main (view) context, or the content indexer's
/// background context. Nonisolated so it runs in the caller's isolation either
/// way; the movie and context must belong together.
///
/// `includeCast` must be `false` when called on a background context (the
/// indexer). Rewriting the `CastMember` relationship there forces CoreData
/// inverse-relationship maintenance to fault objects out of this multi-store
/// CloudKit container, which crashes with an uncatchable `no such table`
/// NSException. The embedding never reads the relationship (only the `actors`
/// string), so the indexer skips it — and skips the `tmdbEnrichedAt` stamp so
/// the detail view still performs a full, cast-included enrichment on the main
/// context the first time the title is opened.
nonisolated func applyMovieDetails(
    _ details: TMDBTitleDetails,
    to movie: Movie,
    context: ModelContext,
    includeCast: Bool = true
) {
    movie.backdropPath = details.backdropPath ?? movie.backdropPath
    movie.logoPath = details.logoPath ?? movie.logoPath
    movie.tagline = details.tagline ?? movie.tagline
    movie.contentRating = details.contentRating ?? movie.contentRating
    movie.imdbId = details.imdbId ?? movie.imdbId
    movie.similarTMDBIds = details.similarIDs
    movie.trailers = details.videos

    if (movie.plot ?? "").isEmpty, let overview = details.overview {
        movie.plot = overview
    }
    if (movie.genre ?? "").isEmpty, !details.genreNames.isEmpty {
        movie.genre = details.genreNames.joined(separator: ", ")
    }
    if (movie.durationSecs ?? 0) == 0, let mins = details.runtimeMinutes, mins > 0 {
        movie.durationSecs = mins * 60
    }
    if movie.rating == 0, let vote = details.voteAverage, vote > 0 {
        movie.rating = vote
    }

    if let collectionId = details.collectionId, collectionId > 0 {
        movie.collectionId = collectionId
        movie.collectionName = details.collectionName
        movie.collectionPosterPath = details.collectionPosterPath
        movie.collectionBackdropPath = details.collectionBackdropPath
    }

    guard includeCast else { return }
    replaceCast(of: movie.castMembers, with: details.cast, ownerId: movie.id, context: context) { castMember in
        castMember.movie = movie
    }

    // Stamp "fully enriched" only once cast is applied; the indexer's partial
    // pass leaves this nil so the detail view completes enrichment later.
    movie.tmdbEnrichedAt = Date()
}

/// Applies TMDB TV series details directly to the given series on the caller's
/// context — the detail views' main (view) context, or the content indexer's
/// background context. Nonisolated so it runs in the caller's isolation either
/// way; the series and context must belong together.
///
/// `includeCast` must be `false` on a background context — see
/// `applyMovieDetails` for why. The series embedding reads the enriched `cast`
/// string (set below, unconditionally), never the `CastMember` relationship.
nonisolated func applySeriesDetails(
    _ details: TMDBTitleDetails,
    to series: Series,
    context: ModelContext,
    includeCast: Bool = true
) {
    series.backdropPath = details.backdropPath ?? series.backdropPath
    series.logoPath = details.logoPath ?? series.logoPath
    series.tagline = details.tagline ?? series.tagline
    series.contentRating = details.contentRating ?? series.contentRating
    series.imdbId = details.imdbId ?? series.imdbId
    series.similarTMDBIds = details.similarIDs
    series.trailers = details.videos

    if (series.plot ?? "").isEmpty, let overview = details.overview {
        series.plot = overview
    }
    if (series.genre ?? "").isEmpty, !details.genreNames.isEmpty {
        series.genre = details.genreNames.joined(separator: ", ")
    }
    if (series.cast ?? "").isEmpty, !details.cast.isEmpty {
        series.cast = details.cast.prefix(6).map(\.name).joined(separator: ", ")
    }
    let currentRating = series.rating.flatMap(Double.init) ?? 0
    if currentRating == 0, let vote = details.voteAverage, vote > 0 {
        series.rating = String(format: "%.1f", vote)
    }

    guard includeCast else { return }
    replaceCast(of: series.castMembers, with: details.cast, ownerId: series.id, context: context) { castMember in
        castMember.series = series
    }

    // Stamp "fully enriched" only once cast is applied; the indexer's partial
    // pass leaves this nil so the detail view completes enrichment later.
    series.tmdbEnrichedAt = Date()
}

// MARK: - Cast helpers

/// Deletes the existing cast for a title and inserts the fresh TMDB billing,
/// wiring each new member to its owner via `assign`.
private nonisolated func replaceCast(
    of existing: [CastMember],
    with cast: [TMDBCastMember],
    ownerId: String,
    context: ModelContext,
    assign: (CastMember) -> Void
) {
    for member in existing {
        context.delete(member)
    }
    for member in cast {
        let castMember = CastMember(
            id: "\(ownerId)-cast-\(member.order)-\(member.tmdbPersonId)",
            tmdbPersonId: member.tmdbPersonId,
            name: member.name,
            role: member.character,
            profilePath: member.profilePath,
            order: member.order
        )
        context.insert(castMember)
        assign(castMember)
    }
}
