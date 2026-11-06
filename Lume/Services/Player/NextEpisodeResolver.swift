import Foundation
import SwiftData

/// Resolves the episode that should play after the one currently on screen, as a
/// value-type `PlayableMedia` the player can swap in directly.
///
/// Unlike the tvOS in-player rail (`TVPlayerContent.seasonEpisodes`), this looks
/// across the whole series ordered by `(season, episode)`, so the successor of a
/// season finale is the first episode of the next season — the natural "play
/// next" behaviour for both auto-advance and the on-screen Next Episode button.
/// Cross-platform: the host (`FullScreenPlayerView`) owns the lookup and hands
/// the result down to whichever engine is active.
nonisolated enum NextEpisodeResolver {
    /// The next episode after `ref` as `PlayableMedia`, or `nil` when `ref` is not
    /// an episode, the series can't be resolved, this is the last episode, or no
    /// playlist can build a URL for it.
    static func nextMedia(
        after ref: PlayableMedia.ContentRef,
        in context: ModelContext,
        client: XtreamClient = XtreamClient()
    ) -> PlayableMedia? {
        guard case let .episode(id) = ref else { return nil }

        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let current = try? context.fetch(descriptor).first,
              let series = current.series else { return nil }

        guard let next = nextEpisode(after: current, in: series, in: context),
              let playlist = playlist(for: series, in: context) else { return nil }
        return PlayableMedia.from(episode: next, playlist: playlist, client: client)
    }

    /// The episode before `ref` as `PlayableMedia`, or `nil` when `ref` is not an
    /// episode, the series can't be resolved, this is the series premiere, or no
    /// playlist can build a URL for it.
    static func previousMedia(
        before ref: PlayableMedia.ContentRef,
        in context: ModelContext,
        client: XtreamClient = XtreamClient()
    ) -> PlayableMedia? {
        guard case let .episode(id) = ref else { return nil }

        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let current = try? context.fetch(descriptor).first,
              let series = current.series else { return nil }

        guard let previous = previousEpisode(before: current, in: series, in: context),
              let playlist = playlist(for: series, in: context) else { return nil }
        return PlayableMedia.from(episode: previous, playlist: playlist, client: client)
    }

    /// The episode immediately after `current` across the series, ordered by
    /// `(seasonNum, episodeNum)`.
    ///
    /// Resolves via bounded `LIMIT 1` fetches rather than traversing
    /// `series.episodes`, which would fault the entire show into memory on the
    /// main actor at every stream change.
    private static func nextEpisode(
        after current: Episode,
        in series: Series,
        in context: ModelContext
    ) -> Episode? {
        let seriesID = series.id
        let currentSeason = current.seasonNum
        let currentEpisode = current.episodeNum

        // 1. Next episode in the same season.
        var sameSeasonDesc = FetchDescriptor<Episode>(
            predicate: #Predicate { episode in
                episode.series?.id == seriesID &&
                episode.seasonNum == currentSeason &&
                episode.episodeNum > currentEpisode
            },
            sortBy: [SortDescriptor(\Episode.episodeNum, order: .forward)]
        )
        sameSeasonDesc.fetchLimit = 1
        if let next = try? context.fetch(sameSeasonDesc).first {
            return next
        }

        // 2. First episode of a subsequent season (crossing the season boundary).
        var laterSeasonDesc = FetchDescriptor<Episode>(
            predicate: #Predicate { episode in
                episode.series?.id == seriesID &&
                episode.seasonNum > currentSeason
            },
            sortBy: [
                SortDescriptor(\Episode.seasonNum, order: .forward),
                SortDescriptor(\Episode.episodeNum, order: .forward)
            ]
        )
        laterSeasonDesc.fetchLimit = 1
        return try? context.fetch(laterSeasonDesc).first
    }

    /// The episode immediately before `current` across the series, ordered by
    /// `(seasonNum, episodeNum)`.
    ///
    /// Resolves via bounded `LIMIT 1` fetches rather than traversing
    /// `series.episodes`.
    private static func previousEpisode(
        before current: Episode,
        in series: Series,
        in context: ModelContext
    ) -> Episode? {
        let seriesID = series.id
        let currentSeason = current.seasonNum
        let currentEpisode = current.episodeNum

        // 1. Previous episode in the same season.
        var sameSeasonDesc = FetchDescriptor<Episode>(
            predicate: #Predicate { episode in
                episode.series?.id == seriesID &&
                episode.seasonNum == currentSeason &&
                episode.episodeNum < currentEpisode
            },
            sortBy: [SortDescriptor(\Episode.episodeNum, order: .reverse)]
        )
        sameSeasonDesc.fetchLimit = 1
        if let previous = try? context.fetch(sameSeasonDesc).first {
            return previous
        }

        // 2. Last episode of the nearest preceding season (crossing season boundary backwards).
        var earlierSeasonDesc = FetchDescriptor<Episode>(
            predicate: #Predicate { episode in
                episode.series?.id == seriesID &&
                episode.seasonNum < currentSeason
            },
            sortBy: [
                SortDescriptor(\Episode.seasonNum, order: .reverse),
                SortDescriptor(\Episode.episodeNum, order: .reverse)
            ]
        )
        earlierSeasonDesc.fetchLimit = 1
        return try? context.fetch(earlierSeasonDesc).first
    }

    /// The playlist that owns a series, mirroring the detail screen and tvOS
    /// overlay logic: prefix-match on the playlist UUID, falling back to the
    /// first playlist.
    private static func playlist(for series: Series, in context: ModelContext) -> Playlist? {
        PlaylistOwner.playlist(forPrefixedID: series.id, in: context)
    }
}
