import Foundation
import SwiftData

/// A single billed cast member for a movie or series, sourced from TMDB credits.
///
/// Each title owns its own cast list (cascade-deleted with the parent), so a
/// `CastMember` belongs to exactly one of `movie` / `series`. The two
/// relationships are independent one-to-manys that happen to share this entity.
@Model
final class CastMember {
    /// Stable per-title id: `"<ownerId>-cast-<order>"`. Lets re-enrichment
    /// upsert the same slot instead of duplicating people.
    @Attribute(.unique) var id: String
    var tmdbPersonId: Int
    var name: String
    /// The character the person plays in this title, when TMDB provides it.
    var role: String?
    /// TMDB profile image path (e.g. `/abc.jpg`); resolve via `TMDBClient.profileURL`.
    var profilePath: String?
    /// Billing order from TMDB (lower = top-billed).
    var order: Int

    var movie: Movie?
    var series: Series?

    init(
        id: String,
        tmdbPersonId: Int,
        name: String,
        role: String? = nil,
        profilePath: String? = nil,
        order: Int = 0,
        movie: Movie? = nil,
        series: Series? = nil
    ) {
        self.id = id
        self.tmdbPersonId = tmdbPersonId
        self.name = name
        self.role = role
        self.profilePath = profilePath
        self.order = order
        self.movie = movie
        self.series = series
    }
}
