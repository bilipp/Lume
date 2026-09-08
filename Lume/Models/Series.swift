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
    // `indexedAt` backs the content indexer's pending/progress scans, run once
    // per chunk for a whole indexing pass.
    #Index<Series>(
        [\.tmdbId],
        [\.isFavorite],
        [\.lastWatchedDate],
        [\.addedToWatchlistDate],
        [\.recommendationVoteRaw],
        [\.categoryId],
        [\.genre],
        [\.indexedAt]
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
    ///
    /// Optional on purpose: a non-optional `[Int] = []` is not free — SwiftData
    /// archives an empty array as a ~219-byte `bplist00` BLOB on every row that
    /// was never enriched, which on a large provider catalog is tens of MB of
    /// pure NSKeyedArchiver round trips written during the cold import. `nil`
    /// means "never enriched" and costs nothing. `trailersData` and
    /// `externalRatingsData` below are optional for the same reason — do not
    /// "tidy" this back to a defaulted array.
    ///
    /// `nil` and `[]` mean the same thing and must be read as such: lightweight
    /// migration leaves rows written by the previous schema holding their
    /// archived empty array, so a pre-upgrade catalog reads `[]` where a freshly
    /// imported one reads `nil`. Never use `nil` as a "never enriched" sentinel.
    var similarTMDBIds: [Int]?
    /// Encoded `[TitleVideo]` blob. SwiftData reliably persists `Data`, whereas a
    /// stored `[TitleVideo]` attribute (a collection of a custom Codable struct)
    /// traps in `ModelCoders` at save time. Access through `trailers`.
    var trailersData: Data?
    @Relationship(deleteRule: .cascade, inverse: \CastMember.series)
    var castMembers: [CastMember] = []

    // MARK: External ratings (MDBList, keyed by TMDB id — lazy-fetched on detail)

    /// IMDb id (e.g. `tt0944947`), resolved from TMDB's external ids. Used for
    /// IntroDB intro/recap-skip lookups.
    var imdbId: String?
    /// Encoded `[ExternalRating]` blob (IMDb / Rotten Tomatoes / Metacritic /
    /// Trakt / Letterboxd / TMDB). A `Data` blob for the same reason as
    /// `trailersData`. Access through `externalRatings`.
    var externalRatingsData: Data?
    /// When ratings were last fetched from MDBList; nil means never.
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

    // MARK: Episode cache (Xtream / Stalker — lazy-fetched on the detail screen)

    /// When this series' episode list was last pulled from the provider; nil
    /// means never. Playlist sync doesn't touch episodes for the lazy pipelines,
    /// so without a stamp a device that already cached a season would never see
    /// a newly added episode. See `episodesAreStale(lastSyncedAt:)`.
    var episodesFetchedAt: Date?
    /// The provider's `lastModified` at the time of that fetch, so a bumped
    /// value invalidates the cache immediately.
    var episodesFetchedLastModified: String?

    var isFavorite: Bool = false
    /// A user-defined order for the unified Favorites collection, spanning movies,
    /// series and live channels. `nil` means "follow the default order"; once the
    /// favorites are reordered in Content Management, every favorite (of any type)
    /// gets a dense value so a series can sit above a channel and the arrangement
    /// survives re-syncs. Mirrors `LiveStream.favoriteOrder`.
    var favoriteOrder: Int?
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
    /// TMDB ids of similar titles. `similarTMDBIds` stores `nil` for "none" —
    /// an empty array still archives a BLOB per row — and reads back as `[]` on
    /// rows the previous schema wrote, so both ends of that rule live here.
    var similarTitleIds: [Int] {
        get { similarTMDBIds ?? [] }
        set { similarTMDBIds = newValue.isEmpty ? nil : newValue }
    }

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

    /// Whether the lazily-fetched episode list should be pulled again.
    ///
    /// Xtream and Stalker episodes are fetched per-series on the detail screen
    /// and are never swept by playlist sync, so a cached season would otherwise
    /// stick forever — an episode the provider added shows up on whichever
    /// device happened to open the series afterwards and stays missing on the
    /// others. Sync is what reopens the question: a `lastModified` the provider
    /// bumped is the exact signal, and a playlist that has synced since the
    /// fetch covers portals that don't maintain the field.
    ///
    /// - Parameter lastSyncedAt: the owning playlist's `lastSyncDate`, stamped
    ///   only when a sync finishes successfully.
    func episodesAreStale(lastSyncedAt: Date?) -> Bool {
        guard let episodesFetchedAt else { return true }
        if episodesFetchedLastModified != lastModified { return true }
        guard let lastSyncedAt else { return false }
        return lastSyncedAt > episodesFetchedAt
    }
}
