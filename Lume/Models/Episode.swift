import Foundation
import SwiftData

@Model
final class Episode {
    // The iCloud reconciler scans episodes by watch state on every pass; index
    // those columns so it seeks the in-progress / watched rows instead of
    // scanning every episode in the catalog.
    #Index<Episode>([\.isWatched], [\.watchProgress])

    @Attribute(.unique) var id: String
    var episodeId: String
    var title: String
    var containerExtension: String
    var seasonNum: Int
    var episodeNum: Int
    var added: String?
    var directSource: String?

    var durationSecs: Int?
    var movieImage: String?
    var plot: String?
    var rating: Double?
    var airDate: String?

    var series: Series?

    var watchProgress: Double = 0.0
    var isWatched: Bool = false

    var downloadStatusRaw: String?
    var localFileURL: String?
    var downloadedAt: Date?
    var lastWatchedDate: Date?

    init(
        id: String,
        episodeId: String,
        title: String,
        containerExtension: String,
        seasonNum: Int,
        episodeNum: Int,
        added: String? = nil,
        directSource: String? = nil,
        series: Series? = nil
    ) {
        self.id = id
        self.episodeId = episodeId
        self.title = title
        self.containerExtension = containerExtension
        self.seasonNum = seasonNum
        self.episodeNum = episodeNum
        self.added = added
        self.directSource = directSource
        self.series = series
    }
}

extension Episode {
    var downloadStatus: DownloadStatus? {
        get {
            guard let raw = downloadStatusRaw else { return nil }
            return DownloadStatus(rawValue: raw)
        }
        set { downloadStatusRaw = newValue?.rawValue }
    }

    /// Marks the episode watched or unwatched, keeping `watchProgress` and
    /// `lastWatchedDate` consistent: a watched episode reads as fully played and
    /// clears any resume point, an unwatched one resets progress to the start.
    func setWatched(_ watched: Bool) {
        isWatched = watched
        if watched {
            watchProgress = Double(durationSecs ?? 0)
            lastWatchedDate = Date()
        } else {
            watchProgress = 0
        }
    }

    /// Whether any episode in the same series is ordered before this one
    /// (earlier season, or same season and earlier episode number).
    var hasEarlierEpisodes: Bool {
        guard let series else { return false }
        return series.episodes.contains {
            ($0.seasonNum, $0.episodeNum) < (seasonNum, episodeNum)
        }
    }

    /// Whether any episode ordered after this one has watched state to clear
    /// (watched, or with resume progress) — the only case where offering to
    /// mark following episodes unwatched is meaningful.
    var hasLaterWatchedEpisodes: Bool {
        guard let series else { return false }
        return series.episodes.contains {
            ($0.seasonNum, $0.episodeNum) > (seasonNum, episodeNum)
                && ($0.isWatched || $0.watchProgress > 0)
        }
    }

    /// Marks every episode in the series ordered before this one as watched.
    func markEarlierEpisodesWatched() {
        guard let series else { return }
        for other in series.episodes
            where (other.seasonNum, other.episodeNum) < (seasonNum, episodeNum) && !other.isWatched
        {
            other.setWatched(true)
        }
    }

    /// Marks every episode in the series ordered after this one as unwatched,
    /// resetting their progress — used to rewind a series' viewing state.
    func markLaterEpisodesUnwatched() {
        guard let series else { return }
        for other in series.episodes
            where (other.seasonNum, other.episodeNum) > (seasonNum, episodeNum)
            && (other.isWatched || other.watchProgress > 0)
        {
            other.setWatched(false)
        }
    }
}
