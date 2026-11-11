import Foundation
import SwiftData

// MARK: - TMDB Enrichment

extension ContentSyncManager {
    /// Fetches TMDB movie details without persisting. The caller applies
    /// the data directly to its own context to avoid cross-context merge
    /// timing issues.
    func fetchTMDBMovieDetails(tmdbId: Int) async throws -> TMDBTitleDetails? {
        let client = tmdbClient
        guard client.isConfigured else { return nil }
        return try await client.movieDetails(tmdbId)
    }

    /// Fetches TMDB TV series details without persisting.
    func fetchTMDBTVDetails(tmdbId: Int) async throws -> TMDBTitleDetails? {
        let client = tmdbClient
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
    ///
    /// A row whose sibling (same TMDB id) is freshly enriched copies it without
    /// a request. The copy carries no cast and leaves `tmdbEnrichedAt` unset:
    /// only the main context writes a copied cast, so the main-context detail
    /// enrichment still completes the row. A fetched result is written to every
    /// sibling without cast, which only the requested row gets. A row that
    /// already holds fresh details (``EnrichedTitleRow/hasFreshTMDBDetails(now:)``) is left
    /// alone.
    func enrichMovie(id: String, tmdbId: Int) async {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let movie = Movie.row(id: id, in: context), !movie.hasFreshTMDBStamp() else { return }
        let source: Movie? = TitleEnrichmentSiblings.freshTMDBSibling(sharing: tmdbId, except: id, in: context)
        guard !movie.hasFreshTMDBDetails(freshSibling: source) else { return }
        if copyDetails(from: source, to: movie, context: context, includeCast: false) {
            try? context.save()
            return
        }
        guard let details = try? await fetchTMDBMovieDetails(tmdbId: tmdbId) else { return }
        applyDetailsToSiblings(
            details, to: movie, tmdbId: tmdbId, context: context, siblingsIncludeCast: false
        )
        try? context.save()
    }

    /// Series counterpart of ``enrichMovie(id:tmdbId:)``.
    func enrichSeries(id: String, tmdbId: Int) async {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let series = Series.row(id: id, in: context), !series.hasFreshTMDBStamp() else { return }
        let source: Series? = TitleEnrichmentSiblings.freshTMDBSibling(sharing: tmdbId, except: id, in: context)
        guard !series.hasFreshTMDBDetails(freshSibling: source) else { return }
        if copyDetails(from: source, to: series, context: context, includeCast: false) {
            try? context.save()
            return
        }
        guard let details = try? await fetchTMDBTVDetails(tmdbId: tmdbId) else { return }
        applyDetailsToSiblings(
            details, to: series, tmdbId: tmdbId, context: context, siblingsIncludeCast: false
        )
        try? context.save()
    }

    /// Fetches the list of TMDB movie IDs that belong to a collection.
    func fetchTMDBCollectionMovieIDs(collectionId: Int) async throws -> [Int] {
        let client = tmdbClient
        guard client.isConfigured else { return [] }
        return try await client.collectionMovieIDs(collectionId)
    }
}

// MARK: - Detail-screen enrichment (view context)

/// Enriches a movie on the detail view's own (main) context: copied from a
/// freshly enriched sibling when there is one, else fetched and written to
/// every sibling, cast included. Returns false when nothing was applied.
@MainActor
func enrichMovieDetails(_ movie: Movie, tmdbId: Int, context: ModelContext) async -> Bool {
    if copyDetailsFromSibling(movie, tmdbId: tmdbId, context: context, includeCast: true) {
        try? context.save()
        return true
    }
    let manager = ContentSyncManager(modelContainer: context.container)
    guard let details = try? await manager.fetchTMDBMovieDetails(tmdbId: tmdbId) else { return false }
    applyDetailsToSiblings(
        details, to: movie, tmdbId: tmdbId, context: context, siblingsIncludeCast: true
    )
    try? context.save()
    return true
}

/// Series counterpart of ``enrichMovieDetails(_:tmdbId:context:)``.
@MainActor
func enrichSeriesDetails(_ series: Series, tmdbId: Int, context: ModelContext) async -> Bool {
    if copyDetailsFromSibling(series, tmdbId: tmdbId, context: context, includeCast: true) {
        try? context.save()
        return true
    }
    let manager = ContentSyncManager(modelContainer: context.container)
    guard let details = try? await manager.fetchTMDBTVDetails(tmdbId: tmdbId) else { return false }
    applyDetailsToSiblings(
        details, to: series, tmdbId: tmdbId, context: context, siblingsIncludeCast: true
    )
    try? context.save()
    return true
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
    movie.similarTitleIds = details.similarIDs
    movie.trailers = details.videos

    if (movie.plot ?? "").isEmpty, let overview = details.overview {
        movie.plot = overview
    }
    // Xtream and M3U VOD lists carry no release date, so TMDB is usually the
    // only source; a provider date that does hold a year is kept.
    if ContentIndexText.year(fromReleaseDate: movie.releaseDate) == nil, let releaseDate = details.releaseDate {
        movie.releaseDate = releaseDate
    }
    // TMDB is the primary genre source: its normalized genre names overwrite any
    // provider-supplied genre once enrichment runs. The provider value is only a
    // fallback shown until then (see `applySeriesFields`; VOD lists carry no genre).
    if !details.genreNames.isEmpty {
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
    series.similarTitleIds = details.similarIDs
    series.trailers = details.videos

    if (series.plot ?? "").isEmpty, let overview = details.overview {
        series.plot = overview
    }
    if ContentIndexText.year(fromReleaseDate: series.releaseDate) == nil, let releaseDate = details.releaseDate {
        series.releaseDate = releaseDate
    }
    // TMDB is the primary genre source: it overwrites the provider genre seeded
    // at sync (see `applySeriesFields`), which serves only as the fallback.
    if !details.genreNames.isEmpty {
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
