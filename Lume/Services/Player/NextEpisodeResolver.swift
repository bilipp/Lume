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

        guard let next = neighbour(of: current, in: series, after: true),
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

        guard let previous = neighbour(of: current, in: series, after: false),
              let playlist = playlist(for: series, in: context) else { return nil }
        return PlayableMedia.from(episode: previous, playlist: playlist, client: client)
    }

    /// The episode adjacent to `current` across the whole series, ordered by
    /// `(season, episode)`.
    ///
    /// A single pass for the nearest key on the chosen side, rather than sorting
    /// the relationship into a second array to read one element out of it: the
    /// episodes are faulted either way, and a long-running show carries hundreds
    /// of them through a lookup that runs on the main actor at every stream
    /// change.
    private static func neighbour(of current: Episode, in series: Series, after: Bool) -> Episode? {
        let currentKey = (current.seasonNum, current.episodeNum)
        var best: Episode?
        for episode in series.episodes where episode.id != current.id {
            let key = (episode.seasonNum, episode.episodeNum)
            guard after ? key > currentKey : key < currentKey else { continue }
            guard let found = best else {
                best = episode
                continue
            }
            let bestKey = (found.seasonNum, found.episodeNum)
            if after ? key < bestKey : key > bestKey { best = episode }
        }
        return best
    }

    /// The playlist that owns a series, mirroring the detail screen and tvOS
    /// overlay logic: prefix-match on the playlist UUID, falling back to the
    /// first playlist.
    private static func playlist(for series: Series, in context: ModelContext) -> Playlist? {
        PlaylistOwner.playlist(forPrefixedID: series.id, in: context)
    }
}
