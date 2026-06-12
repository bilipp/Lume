import Foundation
import SwiftData

@Model
final class Movie {
    @Attribute(.unique) var id: String
    var streamId: Int
    var name: String
    var streamIcon: String?
    var rating: Double
    var rating5Based: Double
    var added: String?
    var containerExtension: String?
    var tmdb: String?
    var num: Int
    var isAdult: Int

    var director: String?
    var actors: String?
    var plot: String?
    var genre: String?
    var releaseDate: String?
    var durationSecs: Int?
    var youtubeTrailer: String?

    // MARK: TMDB enrichment (lazy-fetched on the detail screen)

    /// Wide landscape artwork path used for the detail hero (e.g. `/abc.jpg`).
    var backdropPath: String?
    /// Transparent wordmark-logo path shown in place of the title (e.g. `/abc.png`).
    var logoPath: String?
    var tagline: String?
    /// Localized content rating (e.g. "PG-13", "16").
    var contentRating: String?
    /// When the title was last enriched from TMDB; nil means never.
    var tmdbEnrichedAt: Date?
    /// TMDB ids of similar titles, in TMDB's order, for "You May Also Like".
    var similarTMDBIds: [Int] = []
    /// Encoded `[TitleVideo]` blob. SwiftData reliably persists `Data`, whereas a
    /// stored `[TitleVideo]` attribute (a collection of a custom Codable struct)
    /// traps in `ModelCoders` at save time. Access through `trailers`.
    var trailersData: Data?
    @Relationship(deleteRule: .cascade, inverse: \CastMember.movie)
    var castMembers: [CastMember] = []

    // MARK: External ratings (OMDb, keyed by IMDb id — lazy-fetched on detail)

    /// IMDb id (e.g. `tt3896198`), resolved from TMDB's external ids. Required
    /// to query OMDb for aggregator ratings.
    var imdbId: String?
    /// Encoded `[ExternalRating]` blob (IMDb / Rotten Tomatoes / Metacritic).
    /// A `Data` blob for the same reason as `trailersData`. Access through
    /// `externalRatings`.
    var externalRatingsData: Data?
    /// When ratings were last fetched from OMDb; nil means never.
    var ratingsEnrichedAt: Date?

    // MARK: Content index (built slowly in the background by ContentIndexer)

    /// Mean-pooled `NLContextualEmbedding` vector of the title's index
    /// document, encoded as a raw Float32 blob. Access through `TextEmbedder`.
    var embeddingData: Data?
    /// When the title was last indexed (TMDB resolved + embedding built);
    /// nil means never.
    var indexedAt: Date?

    // MARK: TMDB collection

    var collectionId: Int?
    var collectionName: String?
    var collectionPosterPath: String?
    var collectionBackdropPath: String?

    var categoryId: String?

    /// Full playback URL for movies that come from an m3u playlist. When set,
    /// playback uses it verbatim instead of building an Xtream URL from
    /// credentials and `streamId` (which is a derived hash for m3u sources).
    var directURL: String?

    var isFavorite: Bool = false
    var watchProgress: Double = 0.0
    var isWatched: Bool = false

    var downloadStatusRaw: String?
    var localFileURL: String?
    var downloadedAt: Date?

    var lastWatchedDate: Date?
    var addedToWatchlistDate: Date?

    var traktId: String?
    var tmdbId: Int?

    init(
        id: String,
        streamId: Int,
        name: String,
        streamIcon: String? = nil,
        rating: Double = 0,
        rating5Based: Double = 0,
        added: String? = nil,
        containerExtension: String? = nil,
        tmdb: String? = nil,
        num: Int = 0,
        isAdult: Int = 0,
        categoryId: String? = nil
    ) {
        self.id = id
        self.streamId = streamId
        self.name = name
        self.streamIcon = streamIcon
        self.rating = rating
        self.rating5Based = rating5Based
        self.added = added
        self.containerExtension = containerExtension
        self.tmdb = tmdb
        self.num = num
        self.isAdult = isAdult
        self.categoryId = categoryId
    }
}

enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case completed
    case failed
}

extension Movie {
    /// YouTube videos (trailers, teasers, clips) from TMDB, in display order.
    /// Backed by `trailersData` so SwiftData persists it as a plain `Data` blob.
    var trailers: [TitleVideo] {
        get {
            guard let trailersData else { return [] }
            return (try? JSONDecoder().decode([TitleVideo].self, from: trailersData)) ?? []
        }
        set { trailersData = try? JSONEncoder().encode(newValue) }
    }

    /// Cast in TMDB billing order (top-billed first).
    var orderedCast: [CastMember] {
        castMembers.sorted { $0.order < $1.order }
    }

    /// External aggregator ratings, in display order. Backed by
    /// `externalRatingsData` so SwiftData persists it as a plain `Data` blob.
    var externalRatings: [ExternalRating] {
        get {
            guard let externalRatingsData else { return [] }
            return (try? JSONDecoder().decode([ExternalRating].self, from: externalRatingsData)) ?? []
        }
        set { externalRatingsData = try? JSONEncoder().encode(newValue) }
    }

    var downloadStatus: DownloadStatus? {
        get {
            guard let raw = downloadStatusRaw else { return nil }
            return DownloadStatus(rawValue: raw)
        }
        set { downloadStatusRaw = newValue?.rawValue }
    }
}
