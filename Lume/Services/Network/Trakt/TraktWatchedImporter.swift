//
//  TraktWatchedImporter.swift
//  Lume
//
//  Applies the watched history fetched from Trakt onto the local catalog: marks
//  matching movies and episodes as watched. The reverse direction of the
//  fire-and-forget scrobbling in `TraktService`, run on demand from the Trakt
//  settings screen.
//
//  Matching is by TMDB id (the only external id the library carries), so titles
//  without a resolved `tmdbId` are skipped. Already-watched items are left
//  untouched so the import is idempotent and the returned counts reflect only
//  what actually changed.
//
//  Series need one extra step. Xtream and Stalker episodes are fetched lazily by
//  the series detail screen, so a show the user has never opened has a `Series`
//  row but no `Episode` rows — nothing for the import to mark. Rather than pull
//  every watched show's episodes here (one ~250 KB provider request each), the
//  import parks that state in `TraktPendingWatchedStore` and
//  `Series.insertEpisodes` applies it when the detail screen fetches the
//  episodes anyway. The series' `lastWatchedDate` is stamped immediately either
//  way, so Home's Recently Watched row is right the moment the import finishes.
//

import Foundation
import SwiftData

/// The outcome of an import, surfaced in the settings UI.
struct TraktImportSummary: Equatable {
    var moviesMarked = 0
    var episodesMarked = 0
    /// Shows whose watched episodes were parked because the catalog has no
    /// episodes for them yet. They are applied on first open of the series.
    var showsQueued = 0
    var failed = false

    static let failure = TraktImportSummary(failed: true)

    var markedNothing: Bool {
        !failed && moviesMarked == 0 && episodesMarked == 0 && showsQueued == 0
    }
}

enum TraktWatchedImporter {
    /// Marks the local movies and episodes that Trakt reports as watched, writing
    /// through the given catalog context. Returns what changed.
    static func apply(
        movies: [TraktWatchedMovie],
        shows: [TraktWatchedShow],
        in context: ModelContext
    ) -> TraktImportSummary {
        let moviesMarked = importMovies(movies, in: context)
        let shows = importShows(shows, in: context)

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                return TraktImportSummary(
                    moviesMarked: moviesMarked,
                    episodesMarked: shows.marked,
                    showsQueued: shows.queued,
                    failed: true
                )
            }
        }
        return TraktImportSummary(
            moviesMarked: moviesMarked,
            episodesMarked: shows.marked,
            showsQueued: shows.queued,
            failed: false
        )
    }

    // MARK: - Movies

    private static func importMovies(_ watched: [TraktWatchedMovie], in context: ModelContext) -> Int {
        var watchedIDs = Set<Int>()
        var dates: [Int: Date] = [:]
        for item in watched {
            guard let tmdb = item.movie.ids.tmdb else { continue }
            watchedIDs.insert(tmdb)
            if let date = parse(item.lastWatchedAt) {
                dates[tmdb] = date
            }
        }
        guard !watchedIDs.isEmpty else { return 0 }

        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId != nil })
        let candidates = (try? context.fetch(descriptor)) ?? []

        var count = 0
        for movie in candidates where !movie.isWatched {
            guard let tmdb = movie.tmdbId, watchedIDs.contains(tmdb) else { continue }
            movie.isWatched = true
            movie.watchProgress = Double(movie.durationSecs ?? 0)
            if let date = dates[tmdb] {
                movie.lastWatchedDate = date
            }
            count += 1
        }
        return count
    }

    // MARK: - Shows

    struct SeasonEpisode: Hashable {
        let season: Int
        let episode: Int
    }

    private static func importShows(
        _ watched: [TraktWatchedShow],
        in context: ModelContext
    ) -> (marked: Int, queued: Int) {
        var showsByTMDB: [Int: TraktWatchedShow] = [:]
        for show in watched {
            // A show Trakt reports without any season progress has nothing to
            // apply, now or later.
            guard let tmdb = show.show.ids.tmdb, !show.seasons.isEmpty else { continue }
            showsByTMDB[tmdb] = show
        }
        guard !showsByTMDB.isEmpty else { return (0, 0) }

        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId != nil })
        let candidates = (try? context.fetch(descriptor)) ?? []

        var pending = TraktPendingWatchedStore.load()
        var pendingChanged = false
        var marked = 0
        var queued = 0

        for series in candidates {
            guard let tmdb = series.tmdbId, let show = showsByTMDB[tmdb] else { continue }
            let progress = Progress(show: show)

            // Home's Recently Watched row queries this column, and playback
            // stamps it too (`WatchProgressWriter`). Set it whether or not the
            // episodes exist yet, so an imported show surfaces right away.
            if let newest = progress.newest, newest > (series.lastWatchedDate ?? .distantPast) {
                series.lastWatchedDate = newest
            }

            if series.episodes.isEmpty {
                // Nothing to mark yet. Park it for `Series.insertEpisodes`, which
                // runs when the detail screen fetches the episodes anyway.
                pending[tmdb] = progress.parked
                pendingChanged = true
                queued += 1
            } else {
                marked += markEpisodes(of: series, using: progress)
                // Episodes are present, so anything parked by an earlier import
                // has just been superseded.
                if pending[tmdb] != nil {
                    pending[tmdb] = nil
                    pendingChanged = true
                }
            }
        }

        if pendingChanged {
            TraktPendingWatchedStore.save(pending)
        }
        return (marked, queued)
    }

    // MARK: - Trakt-side progress

    /// One show's watched episodes, in both the form the marking loop wants and
    /// the form that gets parked on disk.
    struct Progress {
        var dates: [SeasonEpisode: Date?] = [:]
        var newest: Date?

        init(show: TraktWatchedShow) {
            for season in show.seasons {
                for episode in season.episodes {
                    let key = SeasonEpisode(season: season.number, episode: episode.number)
                    let date = parse(episode.lastWatchedAt)
                    dates[key] = date
                    if let date, date > (newest ?? .distantPast) {
                        newest = date
                    }
                }
            }
        }

        init(parked: TraktPendingShow) {
            for (key, seconds) in parked.episodes {
                let parts = key.split(separator: "x")
                guard parts.count == 2, let season = Int(parts[0]), let episode = Int(parts[1]) else { continue }
                let date = seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                dates[SeasonEpisode(season: season, episode: episode)] = date
                if let date, date > (newest ?? .distantPast) {
                    newest = date
                }
            }
        }

        var parked: TraktPendingShow {
            var episodes: [String: Int?] = [:]
            for (key, date) in dates {
                episodes[TraktPendingShow.key(season: key.season, episode: key.episode)] =
                    date.map { Int($0.timeIntervalSince1970) }
            }
            return TraktPendingShow(episodes: episodes)
        }
    }

    /// Applies parked Trakt progress to episodes that have just been fetched from
    /// the provider, and drops the entry once it has been used. Called from
    /// `Series.insertEpisodes`, the single place episodes ever materialize.
    @discardableResult
    static func applyPending(to series: Series) -> Int {
        guard let tmdb = series.tmdbId, !series.episodes.isEmpty else { return 0 }
        let pending = TraktPendingWatchedStore.load()
        guard let parked = pending[tmdb] else { return 0 }

        let progress = Progress(parked: parked)
        let marked = markEpisodes(of: series, using: progress)
        if let newest = progress.newest, newest > (series.lastWatchedDate ?? .distantPast) {
            series.lastWatchedDate = newest
        }
        TraktPendingWatchedStore.clear(tmdbID: tmdb)
        return marked
    }

    /// Marks the episodes of `series` that Trakt reports watched, returning how
    /// many changed.
    private static func markEpisodes(of series: Series, using progress: Progress) -> Int {
        var count = 0
        for episode in series.episodes where !episode.isWatched {
            let key = SeasonEpisode(season: episode.seasonNum, episode: episode.episodeNum)
            guard let date = progress.dates[key] else { continue }
            episode.isWatched = true
            episode.watchProgress = Double(episode.durationSecs ?? 0)
            if let date {
                episode.lastWatchedDate = date
            }
            count += 1
        }
        return count
    }

    // MARK: - Dates

    /// Parses Trakt's ISO-8601 timestamps, which carry fractional seconds
    /// (e.g. `2014-10-11T17:00:54.000Z`).
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return formatter.date(from: string)
    }
}
