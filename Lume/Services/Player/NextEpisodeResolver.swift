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
enum NextEpisodeResolver {
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

        let ordered = series.episodes.sorted {
            ($0.seasonNum, $0.episodeNum) < ($1.seasonNum, $1.episodeNum)
        }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }),
              index + 1 < ordered.count else { return nil }

        let next = ordered[index + 1]
        guard let playlist = playlist(for: series, in: context) else { return nil }
        return PlayableMedia.from(episode: next, playlist: playlist, client: client)
    }

    /// The playlist that owns a series, mirroring the detail screen and tvOS
    /// overlay logic: prefix-match on the playlist UUID, falling back to the
    /// first playlist.
    private static func playlist(for series: Series, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }
}
