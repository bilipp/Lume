import Foundation
import SwiftData

@Model
final class Series {
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
    var tagline: String?
    /// Localized content rating (e.g. "TV-MA", "16").
    var contentRating: String?
    /// When the title was last enriched from TMDB; nil means never.
    var tmdbEnrichedAt: Date?
    /// TMDB ids of similar titles, in TMDB's order, for "You May Also Like".
    var similarTMDBIds: [Int] = []
    /// YouTube videos (trailers, teasers, clips) from TMDB, in display order.
    var trailers: [TitleVideo] = []
    @Relationship(deleteRule: .cascade, inverse: \CastMember.series)
    var castMembers: [CastMember] = []

    var categoryId: String?
    @Relationship(deleteRule: .cascade) var episodes: [Episode] = []

    var isFavorite: Bool = false
    var lastWatchedDate: Date?
    var addedToWatchlistDate: Date?
    var traktId: String?
    var tmdbId: Int?

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
    /// Cast in TMDB billing order (top-billed first).
    var orderedCast: [CastMember] {
        castMembers.sorted { $0.order < $1.order }
    }
}
