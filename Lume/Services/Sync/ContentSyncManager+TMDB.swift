import Foundation
import SwiftData

// MARK: - TMDB Enrichment

extension ContentSyncManager {
    /// Enriches a movie with TMDB detail data (backdrop, tagline, content
    /// rating, billed cast and similar titles), filling any gaps the Xtream
    /// provider left in the core metadata. Writes on a background context;
    /// the detail view observes the change through its `@Query`-backed model.
    func enrichMovie(id: String, tmdbId: Int) async throws {
        let client = TMDBClient.shared
        guard client.isConfigured else { return }
        let details = try await client.movieDetails(tmdbId)

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let movie = try context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        ).first else { return }

        movie.backdropPath = details.backdropPath ?? movie.backdropPath
        movie.tagline = details.tagline ?? movie.tagline
        movie.contentRating = details.contentRating ?? movie.contentRating
        movie.similarTMDBIds = details.similarIDs

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

        replaceCast(of: movie.castMembers, with: details.cast, ownerId: id, context: context) { castMember in
            castMember.movie = movie
        }

        movie.tmdbEnrichedAt = Date()
        try context.save()
    }

    /// Enriches a series with TMDB detail data. Mirrors `enrichMovie`, adapting
    /// to the series model's `String` rating and lack of a runtime field.
    func enrichSeries(id: String, tmdbId: Int) async throws {
        let client = TMDBClient.shared
        guard client.isConfigured else { return }
        let details = try await client.tvDetails(tmdbId)

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let series = try context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        ).first else { return }

        series.backdropPath = details.backdropPath ?? series.backdropPath
        series.tagline = details.tagline ?? series.tagline
        series.contentRating = details.contentRating ?? series.contentRating
        series.similarTMDBIds = details.similarIDs

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

        replaceCast(of: series.castMembers, with: details.cast, ownerId: id, context: context) { castMember in
            castMember.series = series
        }

        series.tmdbEnrichedAt = Date()
        try context.save()
    }

    /// Deletes the existing cast for a title and inserts the fresh TMDB billing,
    /// wiring each new member to its owner via `assign`.
    private func replaceCast(
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
}
