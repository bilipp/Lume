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

    /// Fetches and persists TMDB movie enrichment **off the main thread**.
    ///
    /// Detail views used to apply enrichment on the view's main context and call
    /// `modelContext.save()` synchronously — a main-thread store write (scalar
    /// fields plus a full cast replace) on the hot path of every detail open. Here
    /// the fetch, apply and save all run on the engine actor's own background
    /// context; SwiftData auto-merges the save into the main context, so the
    /// on-screen `@Model` (and its `@Query`s) update without the caller blocking.
    func enrichMovie(id: String, tmdbId: Int) async {
        guard let details = try? await fetchTMDBMovieDetails(tmdbId: tmdbId) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? context.fetch(descriptor).first else { return }
        applyMovieDetails(details, to: movie, context: context)
        try? context.save()
    }

    /// Series counterpart of ``enrichMovie(id:tmdbId:)``.
    func enrichSeries(id: String, tmdbId: Int) async {
        guard let details = try? await fetchTMDBTVDetails(tmdbId: tmdbId) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let series = try? context.fetch(descriptor).first else { return }
        applySeriesDetails(details, to: series, context: context)
        try? context.save()
    }

    /// Fetches the list of TMDB movie IDs that belong to a collection.
    func fetchTMDBCollectionMovieIDs(collectionId: Int) async throws -> [Int] {
        let client = TMDBClient.shared
        guard client.isConfigured else { return [] }
        return try await client.collectionMovieIDs(collectionId)
    }
}

// MARK: - Direct context apply

/// Applies TMDB movie details to the given movie on the caller's context.
/// `nonisolated` so it can run on a background context (see ``ContentSyncManager
/// /enrichMovie(id:tmdbId:)``) as well as on the main context (the Home hero
/// path); it only touches `@Model` properties and the passed-in context.
nonisolated func applyMovieDetails(_ details: TMDBTitleDetails, to movie: Movie, context: ModelContext) {
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

    replaceCast(of: movie.castMembers, with: details.cast, ownerId: movie.id, context: context) { castMember in
        castMember.movie = movie
    }

    movie.tmdbEnrichedAt = Date()
}

/// Applies TMDB TV series details to the given series on the caller's context.
/// `nonisolated` for the same reason as ``applyMovieDetails(_:to:context:)``.
nonisolated func applySeriesDetails(_ details: TMDBTitleDetails, to series: Series, context: ModelContext) {
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

    replaceCast(of: series.castMembers, with: details.cast, ownerId: series.id, context: context) { castMember in
        castMember.series = series
    }

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
