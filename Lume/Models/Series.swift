import Foundation
import SwiftData

@Model
final class Series {
    // Home's trending/watchlist rows look titles up by `tmdbId`. The home
    // screen's `@Query`s (Recently Watched / Favorites) and the iCloud
    // reconciler also filter by user-state columns; index those so a foreground
    // CloudKit merge seeks instead of scanning the whole catalog on the main
    // thread (the unindexed scan froze the app on tvOS returning from
    // background).
    // `categoryId` is the primary filter for every category browse/preview and
    // `genre` for the browse-by-genre derivation; index both so opening a
    // category or switching playlists seeks instead of scanning the whole
    // catalog on a large library.
    #Index<Series>(
        [\.tmdbId],
        [\.isFavorite],
        [\.lastWatchedDate],
        [\.addedToWatchlistDate],
        [\.recommendationVoteRaw],
        [\.categoryId],
        [\.genre]
    )

    @Attribute(.unique) var id: String
    var seriesId: Int
    var name: String
    var cover: String?
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var releaseDate: String?
    var lastModified: String?
    var rating: String?
    var rating5Based: String?
    var tmdb: String?
    var num: Int

    // MARK: TMDB enrichment (lazy-fetched on the detail screen)

    /// Wide landscape artwork path used for the detail hero (e.g. `/abc.jpg`).
    var backdropPath: String?
    /// Transparent wordmark-logo path shown in place of the title (e.g. `/abc.png`).
    var logoPath: String?
    var tagline: String?
    /// Localized content rating (e.g. "TV-MA", "16").
    var contentRating: String?
    /// When the title was last enriched from TMDB; nil means never.
    var tmdbEnrichedAt: Date?
    /// TMDB ids of similar titles, in TMDB's order, for "You May Also Like".
    var similarTMDBIds: [Int] = []
    /// Encoded `[TitleVideo]` blob. SwiftData reliably persists `Data`, whereas a
    /// stored `[TitleVideo]` attribute (a collection of a custom Codable struct)
    /// traps in `ModelCoders` at save time. Access through `trailers`.
    var trailersData: Data?
    @Relationship(deleteRule: .cascade, inverse: \CastMember.series)
    var castMembers: [CastMember] = []

    // MARK: External ratings (OMDb, keyed by IMDb id — lazy-fetched on detail)

    /// IMDb id (e.g. `tt0944947`), resolved from TMDB's external ids. Required
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

    var categoryId: String?
    @Relationship(deleteRule: .cascade) var episodes: [Episode] = []

    var isFavorite: Bool = false
    var lastWatchedDate: Date?
    var addedToWatchlistDate: Date?
    var traktId: String?
    var tmdbId: Int?

    /// The user's "For You" vote, as a raw value (`0` none, `1` up, `-1` down).
    /// Mirrored to `UserContentState` so it syncs via iCloud. Access through
    /// `recommendationVote`.
    var recommendationVoteRaw: Int = 0

    init(
        id: String,
        seriesId: Int,
        name: String,
        cover: String? = nil,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        releaseDate: String? = nil,
        lastModified: String? = nil,
        rating: String? = nil,
        rating5Based: String? = nil,
        tmdb: String? = nil,
        num: Int = 0,
        categoryId: String? = nil
    ) {
        self.id = id
        self.seriesId = seriesId
        self.name = name
        self.cover = cover
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.releaseDate = releaseDate
        self.lastModified = lastModified
        self.rating = rating
        self.rating5Based = rating5Based
        self.tmdb = tmdb
        self.num = num
        self.categoryId = categoryId
    }
}

extension Series {
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

    /// The user's "For You" vote, or nil when unvoted.
    var recommendationVote: RecommendationVote? {
        get { RecommendationVote(rawValue: recommendationVoteRaw) }
        set { recommendationVoteRaw = newValue?.rawValue ?? 0 }
    }
}
