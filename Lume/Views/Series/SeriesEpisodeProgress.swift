//
//  SeriesEpisodeProgress.swift
//  Lume
//
//  Single-pass derivations over a series' episodes relationship, shared by
//  `SeriesDetailView` and `TVSeriesDetailView`. Their bodies read the play
//  target on every evaluation; deriving it with per-property computed vars
//  re-filtered and re-sorted the full relationship several times per render,
//  which visibly lagged watched-toggles and focus moves on long-running shows
//  (hundreds to thousands of episodes). Everything here is O(episodes) scans
//  with no sorting and no intermediate arrays.
//

enum SeriesEpisodeProgress {
    /// The furthest episodes by watch state, in (season, episode) order.
    struct Markers {
        /// Furthest partially-watched (not completed) episode.
        var furthestInProgress: Episode?
        /// Furthest episode with any progress, including completed ones.
        var furthestAnyProgress: Episode?
        /// Furthest fully-watched episode.
        var furthestWatched: Episode?
    }

    /// All three markers from one scan.
    static func markers(in episodes: [Episode]) -> Markers {
        var markers = Markers()
        for episode in episodes {
            if episode.watchProgress > 1, !episode.isWatched {
                markers.furthestInProgress = later(markers.furthestInProgress, episode)
            }
            if episode.watchProgress > 0 || episode.isWatched {
                markers.furthestAnyProgress = later(markers.furthestAnyProgress, episode)
            }
            if episode.isWatched {
                markers.furthestWatched = later(markers.furthestWatched, episode)
            }
        }
        return markers
    }

    /// Play button target: resume the furthest in-progress episode; else the
    /// episode after the furthest watched one (overflowing seasons, wrapping to
    /// the premiere after the finale); else `fallback` (the selected season's
    /// first episode); else the series premiere.
    static func nextEpisode(in episodes: [Episode], fallback: @autoclosure () -> Episode?) -> Episode? {
        let markers = markers(in: episodes)
        if let inProgress = markers.furthestInProgress { return inProgress }
        guard let watched = markers.furthestWatched else {
            return fallback() ?? earliest(in: episodes)
        }
        return successor(of: watched, in: episodes)
    }

    /// The episode after `watched` in (season, episode) order, wrapping to the
    /// series premiere after the finale.
    private static func successor(of watched: Episode, in episodes: [Episode]) -> Episode? {
        var next: Episode?
        var first: Episode?
        for episode in episodes {
            first = earlier(first, episode)
            if (watched.seasonNum, watched.episodeNum) < (episode.seasonNum, episode.episodeNum) {
                next = earlier(next, episode)
            }
        }
        return next ?? first
    }

    private static func earliest(in episodes: [Episode]) -> Episode? {
        episodes.reduce(nil) { earlier($0, $1) }
    }

    private static func later(_ current: Episode?, _ candidate: Episode) -> Episode {
        guard let current else { return candidate }
        return (current.seasonNum, current.episodeNum) < (candidate.seasonNum, candidate.episodeNum)
            ? candidate
            : current
    }

    private static func earlier(_ current: Episode?, _ candidate: Episode) -> Episode {
        guard let current else { return candidate }
        return (candidate.seasonNum, candidate.episodeNum) < (current.seasonNum, current.episodeNum)
            ? candidate
            : current
    }
}
