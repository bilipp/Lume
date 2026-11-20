//
//  TitleEnrichmentSiblings.swift
//  Lume
//
//  TMDB details and MDBList ratings belong to the title, not the catalog row:
//  every row sharing a TMDB id (other qualities, languages, playlists) gets the
//  same data. A row whose sibling is already enriched copies it instead of
//  fetching, and a fetched result is written to every sibling.
//

import Foundation
import SwiftData

/// The enrichment columns copied between rows of one title.
nonisolated protocol EnrichedTitleRow: TitleSiblingRow {
    var tmdbEnrichedAt: Date? { get }
    var ratingsEnrichedAt: Date? { get set }
    var externalRatingsData: Data? { get set }
    var castMembers: [CastMember] { get }
    var orderedCast: [CastMember] { get }

    /// The TMDB payload this row holds: ``TitleEnrichmentSiblings/details(from:)-(Movie)``.
    var tmdbDetails: TMDBTitleDetails { get }
    /// What this row holds of `source`'s fields, for
    /// ``TitleEnrichmentSiblings/holds(_:in:)``; nil when it lacks something
    /// that comparison leaves out.
    func heldTMDBDetails(against source: TMDBTitleDetails) -> TMDBTitleDetails?
    /// `applyMovieDetails` / `applySeriesDetails`.
    func applyTMDBDetails(_ details: TMDBTitleDetails, context: ModelContext, includeCast: Bool)
    /// The row other than `id` with TMDB id `tmdbId` and the latest `stamp`.
    static func latestSibling(
        sharing tmdbId: Int,
        except id: String,
        by stamp: EnrichmentStamp,
        in context: ModelContext
    ) -> Self?
}

nonisolated enum EnrichmentStamp {
    case tmdb
    case ratings
}

nonisolated extension Movie: EnrichedTitleRow {
    var tmdbDetails: TMDBTitleDetails {
        TitleEnrichmentSiblings.details(from: self)
    }

    func heldTMDBDetails(against _: TMDBTitleDetails) -> TMDBTitleDetails? {
        // A copy fills the runtime only when the row has none, so any duration
        // counts as held — even one under a minute, which `details(from:)`
        // rounds down to zero.
        var current = tmdbDetails
        current.runtimeMinutes = (durationSecs ?? 0) > 0 ? max(current.runtimeMinutes ?? 0, 1) : nil
        return current
    }

    func applyTMDBDetails(_ details: TMDBTitleDetails, context: ModelContext, includeCast: Bool) {
        applyMovieDetails(details, to: self, context: context, includeCast: includeCast)
    }

    static func latestSibling(
        sharing tmdbId: Int,
        except id: String,
        by stamp: EnrichmentStamp,
        in context: ModelContext
    ) -> Movie? {
        let value: Int? = tmdbId
        var descriptor = switch stamp {
        case .tmdb:
            FetchDescriptor<Movie>(
                predicate: #Predicate { $0.tmdbId == value && $0.id != id && $0.tmdbEnrichedAt != nil },
                sortBy: [SortDescriptor(\.tmdbEnrichedAt, order: .reverse)]
            )
        case .ratings:
            FetchDescriptor<Movie>(
                predicate: #Predicate { $0.tmdbId == value && $0.id != id && $0.ratingsEnrichedAt != nil },
                sortBy: [SortDescriptor(\.ratingsEnrichedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

nonisolated extension Series: EnrichedTitleRow {
    var tmdbDetails: TMDBTitleDetails {
        TitleEnrichmentSiblings.details(from: self)
    }

    func heldTMDBDetails(against source: TMDBTitleDetails) -> TMDBTitleDetails? {
        guard source.cast.isEmpty || !(cast ?? "").isEmpty else { return nil }
        return tmdbDetails
    }

    func applyTMDBDetails(_ details: TMDBTitleDetails, context: ModelContext, includeCast: Bool) {
        applySeriesDetails(details, to: self, context: context, includeCast: includeCast)
    }

    static func latestSibling(
        sharing tmdbId: Int,
        except id: String,
        by stamp: EnrichmentStamp,
        in context: ModelContext
    ) -> Series? {
        let value: Int? = tmdbId
        var descriptor = switch stamp {
        case .tmdb:
            FetchDescriptor<Series>(
                predicate: #Predicate { $0.tmdbId == value && $0.id != id && $0.tmdbEnrichedAt != nil },
                sortBy: [SortDescriptor(\.tmdbEnrichedAt, order: .reverse)]
            )
        case .ratings:
            FetchDescriptor<Series>(
                predicate: #Predicate { $0.tmdbId == value && $0.id != id && $0.ratingsEnrichedAt != nil },
                sortBy: [SortDescriptor(\.ratingsEnrichedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

nonisolated enum TitleEnrichmentSiblings {
    /// How long a TMDB or MDBList enrichment stays fresh — the detail
    /// screens' re-fetch window.
    static let freshness: TimeInterval = 14 * 24 * 3600

    /// The most recently, still freshly enriched row, if any.
    static func freshest<Row: EnrichedTitleRow>(
        _ rows: [Row],
        by stamp: (Row) -> Date?,
        now: Date = Date()
    ) -> Row? {
        rows
            .compactMap { row in stamp(row).map { (row, $0) } }
            .filter { now.timeIntervalSince($0.1) < freshness }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// The most recently enriched sibling of `row` (same TMDB id), if its TMDB
    /// details are still fresh.
    static func freshTMDBSibling<Row: EnrichedTitleRow>(of row: Row, now: Date = Date()) -> Row? {
        guard let tmdbId = row.titleTMDBId, let context = row.modelContext else { return nil }
        return freshTMDBSibling(sharing: tmdbId, except: row.id, in: context, now: now)
    }

    /// ``freshTMDBSibling(of:now:)`` for a row given by id.
    static func freshTMDBSibling<Row: EnrichedTitleRow>(
        sharing tmdbId: Int,
        except id: String,
        in context: ModelContext,
        now: Date = Date()
    ) -> Row? {
        let latest = Row.latestSibling(sharing: tmdbId, except: id, by: .tmdb, in: context)
        return latest.flatMap { freshest([$0], by: \.tmdbEnrichedAt, now: now) }
    }

    // MARK: TMDB details

    /// The TMDB payload a fully enriched movie row holds, so a sibling can be
    /// enriched from it without a request.
    static func details(from movie: Movie) -> TMDBTitleDetails {
        TMDBTitleDetails(
            backdropPath: movie.backdropPath,
            tagline: movie.tagline,
            overview: movie.plot,
            voteAverage: movie.rating > 0 ? movie.rating : nil,
            releaseDate: movie.releaseDate,
            runtimeMinutes: movie.durationSecs.map { $0 / 60 },
            genreNames: genreNames(movie.genre),
            contentRating: movie.contentRating,
            cast: cast(movie.castMembers),
            similarIDs: movie.similarTitleIds,
            videos: movie.trailers,
            logoPath: movie.logoPath,
            imdbId: movie.imdbId,
            collectionId: movie.collectionId,
            collectionName: movie.collectionName,
            collectionPosterPath: movie.collectionPosterPath,
            collectionBackdropPath: movie.collectionBackdropPath
        )
    }

    /// Series counterpart of ``details(from:)-(Movie)``.
    static func details(from series: Series) -> TMDBTitleDetails {
        let vote = series.rating.flatMap(Double.init) ?? 0
        return TMDBTitleDetails(
            backdropPath: series.backdropPath,
            tagline: series.tagline,
            overview: series.plot,
            voteAverage: vote > 0 ? vote : nil,
            releaseDate: series.releaseDate,
            genreNames: genreNames(series.genre),
            contentRating: series.contentRating,
            cast: cast(series.castMembers),
            similarIDs: series.similarTitleIds,
            videos: series.trailers,
            logoPath: series.logoPath,
            imdbId: series.imdbId
        )
    }

    /// The freshest enriched sibling's cast, for a row with no cast of its own:
    /// a background sibling copy never writes cast. Empty when the row has cast.
    static func siblingCast<Row: EnrichedTitleRow>(of row: Row, in context: ModelContext) -> [CastMember] {
        guard row.castMembers.isEmpty, let tmdbId = row.titleTMDBId else { return [] }
        let source: Row? = freshTMDBSibling(sharing: tmdbId, except: row.id, in: context)
        return source?.orderedCast ?? []
    }

    /// Whether a row holding `row` already has everything a copy of `source`
    /// would write, cast aside — the field rules of
    /// ``applyMovieDetails(_:to:context:includeCast:)``.
    static func holds(_ source: TMDBTitleDetails, in row: TMDBTitleDetails) -> Bool {
        func kept<Value: Equatable>(_ value: Value?, _ current: Value?) -> Bool {
            value == nil || value == current
        }
        return kept(source.backdropPath, row.backdropPath)
            && kept(source.logoPath, row.logoPath)
            && kept(source.tagline, row.tagline)
            && kept(source.contentRating, row.contentRating)
            && kept(source.imdbId, row.imdbId)
            && source.similarIDs == row.similarIDs
            && source.videos == row.videos
            && (source.genreNames.isEmpty || source.genreNames == row.genreNames)
            && ((source.overview ?? "").isEmpty || !(row.overview ?? "").isEmpty)
            && (source.releaseDate == nil || source.releaseDate == row.releaseDate
                || ContentIndexText.year(fromReleaseDate: row.releaseDate) != nil)
            && (source.voteAverage == nil || row.voteAverage != nil)
            && ((source.runtimeMinutes ?? 0) <= 0 || (row.runtimeMinutes ?? 0) > 0)
            && ((source.collectionId ?? 0) <= 0 || source.collectionId == row.collectionId)
    }

    private static func genreNames(_ genre: String?) -> [String] {
        (genre ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func cast(_ members: [CastMember]) -> [TMDBCastMember] {
        members.sorted { $0.order < $1.order }.map {
            TMDBCastMember(
                tmdbPersonId: $0.tmdbPersonId,
                name: $0.name,
                character: $0.role,
                profilePath: $0.profilePath,
                order: $0.order
            )
        }
    }

    // MARK: MDBList ratings

    /// Copies the freshest sibling's ratings onto `row`. Returns false when no
    /// sibling has fresh ratings, so the caller fetches.
    static func copyRatings<Row: EnrichedTitleRow>(from siblings: [Row], to row: Row) -> Bool {
        guard let source = freshest(siblings, by: \.ratingsEnrichedAt) else { return false }
        row.externalRatingsData = source.externalRatingsData
        row.ratingsEnrichedAt = source.ratingsEnrichedAt
        return true
    }

    /// Writes fetched ratings to `row` and every sibling.
    static func applyRatings<Row: EnrichedTitleRow>(
        _ ratings: [ExternalRating],
        to row: Row,
        siblings: [Row],
        now: Date = Date()
    ) {
        let data = try? JSONEncoder().encode(ratings)
        for target in [row] + siblings {
            target.externalRatingsData = data
            target.ratingsEnrichedAt = now
        }
    }
}

// MARK: - TMDB freshness

nonisolated extension EnrichedTitleRow {
    /// Whether the TMDB details are fresh: stamped within
    /// ``TitleEnrichmentSiblings/freshness``, or already copied from a freshly
    /// enriched sibling. A background sibling copy never stamps the row (it
    /// writes no cast; the detail screens show the sibling's), so the stamp
    /// alone would copy and save the same details on every open.
    func hasFreshTMDBDetails(now: Date = Date()) -> Bool {
        hasFreshTMDBStamp(now: now)
            || holdsTMDBDetails(of: TitleEnrichmentSiblings.freshTMDBSibling(of: self, now: now))
    }

    /// ``hasFreshTMDBDetails(now:)`` against an already fetched
    /// ``TitleEnrichmentSiblings/freshTMDBSibling(of:now:)``.
    func hasFreshTMDBDetails(freshSibling: Self?, now: Date = Date()) -> Bool {
        hasFreshTMDBStamp(now: now) || holdsTMDBDetails(of: freshSibling)
    }

    func hasFreshTMDBStamp(now: Date = Date()) -> Bool {
        guard let tmdbEnrichedAt else { return false }
        return now.timeIntervalSince(tmdbEnrichedAt) < TitleEnrichmentSiblings.freshness
    }

    /// Whether this row already holds everything a copy of `source` would write.
    func holdsTMDBDetails(of source: Self?) -> Bool {
        guard let source else { return false }
        let details = source.tmdbDetails
        guard let current = heldTMDBDetails(against: details) else { return false }
        return TitleEnrichmentSiblings.holds(details, in: current)
    }
}

// MARK: - TMDB fan-out

/// Enriches `row` from a freshly enriched sibling with the same TMDB id, if
/// there is one. Returns false when there is none, so the caller fetches.
nonisolated func copyDetailsFromSibling<Row: EnrichedTitleRow>(
    _ row: Row,
    tmdbId: Int,
    context: ModelContext,
    includeCast: Bool
) -> Bool {
    let source: Row? = TitleEnrichmentSiblings.freshTMDBSibling(sharing: tmdbId, except: row.id, in: context)
    return copyDetails(from: source, to: row, context: context, includeCast: includeCast)
}

/// Enriches `row` from `source`, an already fetched fresh sibling. Returns
/// false when there is none.
nonisolated func copyDetails<Row: EnrichedTitleRow>(
    from source: Row?,
    to row: Row,
    context: ModelContext,
    includeCast: Bool
) -> Bool {
    guard let source else { return false }
    row.applyTMDBDetails(source.tmdbDetails, context: context, includeCast: includeCast)
    return true
}

/// Applies fetched TMDB details, cast included, to `row`, and to every other
/// row with the same TMDB id. `siblingsIncludeCast` must be false on a
/// background context — see ``applyMovieDetails(_:to:context:includeCast:)``.
nonisolated func applyDetailsToSiblings(
    _ details: TMDBTitleDetails,
    to row: some EnrichedTitleRow,
    tmdbId: Int,
    context: ModelContext,
    siblingsIncludeCast: Bool
) {
    row.applyTMDBDetails(details, context: context, includeCast: true)
    for sibling in type(of: row).rows(sharing: tmdbId, except: row.id, in: context) {
        sibling.applyTMDBDetails(details, context: context, includeCast: siblingsIncludeCast)
    }
}
