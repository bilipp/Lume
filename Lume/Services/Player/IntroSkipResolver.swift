import Foundation
import SwiftData

/// Resolves the IntroDB lookup key — the *series'* IMDb id plus the season and
/// episode numbers — for the content currently playing.
///
/// IntroDB only indexes episodic TV (its segments endpoint requires a season
/// and episode), so movies and live streams resolve to `nil` and simply get no
/// skip affordance. Cross-platform: the host (`FullScreenPlayerView`) owns the
/// lookup and the async fetch, handing the result down to whichever engine is
/// active — mirroring `NextEpisodeResolver`.
enum IntroSkipResolver {
    struct Lookup: Equatable {
        let imdbId: String
        let season: Int
        let episode: Int
    }

    /// The IntroDB lookup key for `ref`, or `nil` when it is not an episode, the
    /// episode / series can't be resolved, or the series carries no IMDb id.
    static func lookup(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Lookup? {
        guard case let .episode(id) = ref else { return nil }

        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let episode = try? context.fetch(descriptor).first,
              let imdbId = episode.series?.imdbId?.trimmingCharacters(in: .whitespaces),
              !imdbId.isEmpty else { return nil }

        return Lookup(imdbId: imdbId, season: episode.seasonNum, episode: episode.episodeNum)
    }
}
