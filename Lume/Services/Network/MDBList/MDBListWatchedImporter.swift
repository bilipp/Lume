//
//  MDBListWatchedImporter.swift
//  Lume
//
//  Applies the watched history fetched from MDBList onto the local catalog:
//  marks matching movies and episodes as watched. The reverse direction of the
//  fire-and-forget syncing in `MDBListService`, run on connect and on demand
//  from the MDBList settings screen.
//
//  Matching is by TMDB id, so titles without a resolved `tmdbId` are skipped.
//  Already-watched items are left untouched so the import is idempotent and the
//  returned counts reflect only what actually changed.
//
//  Episodes of a show the user has never opened don't exist locally yet (Xtream
//  and Stalker fetch them lazily on the detail screen), so their watched state
//  is parked in `MDBListPendingWatchedStore` and applied by
//  `Series.insertEpisodes` — the same approach as `SimklWatchedImporter`.
//

import Foundation
import SwiftData

/// The outcome of an import, surfaced in the settings UI.
nonisolated struct MDBListImportSummary: Equatable {
    var moviesMarked = 0
    var episodesMarked = 0
    /// Shows whose watched episodes were parked because the catalog has no
    /// episodes for them yet. They are applied on first open of the series.
    var showsQueued = 0
    var failed = false

    static let failure = MDBListImportSummary(failed: true)

    var markedNothing: Bool {
        !failed && moviesMarked == 0 && episodesMarked == 0 && showsQueued == 0
    }
}

nonisolated enum MDBListWatchedImporter {
    /// Marks the local movies and episodes that MDBList reports as watched,
    /// writing through the given catalog context. Returns what changed.
    static func apply(history: MDBListWatchedHistory, in context: ModelContext) -> MDBListImportSummary {
        let moviesMarked = importMovies(history.movies, in: context)
        let shows = importEpisodes(history.episodes, in: context)
        var summary = MDBListImportSummary(
            moviesMarked: moviesMarked,
            episodesMarked: shows.marked,
            showsQueued: shows.queued
        )
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                summary.failed = true
            }
        }
        return summary
    }

    // MARK: - Movies

    private static func importMovies(_ watched: [MDBListWatchedMovie], in context: ModelContext) -> Int {
        var dates: [Int: Date] = [:]
        for item in watched {
            guard let tmdb = item.movie.ids.tmdb, let date = MDBListDates.parse(item.lastWatchedAt) else { continue }
            dates[tmdb] = max(date, dates[tmdb] ?? .distantPast)
        }
        guard !dates.isEmpty else { return 0 }

        var count = 0
        for movie in fetch(Movie.self, tmdbIDs: Set(dates.keys), predicate: movieTmdbIdPredicate, in: context)
            where !movie.isWatched
        {
            guard let tmdb = movie.tmdbId, let date = dates[tmdb] else { continue }
            movie.isWatched = true
            movie.watchProgress = Double(movie.durationSecs ?? 0)
            movie.lastWatchedDate = date
            count += 1
        }
        return count
    }

    // MARK: - Episodes

    struct SeasonEpisode: Hashable {
        let season: Int
        let episode: Int
    }

    /// One show's watched episodes, keyed by season and episode number.
    struct Progress {
        var dates: [SeasonEpisode: Date] = [:]

        var newest: Date? {
            dates.values.max()
        }

        init() {}

        init(parked: MDBListPendingShow) {
            for (key, seconds) in parked.episodes {
                let parts = key.split(separator: "x")
                guard parts.count == 2, let season = Int(parts[0]), let episode = Int(parts[1]),
                      let seconds else { continue }
                dates[SeasonEpisode(season: season, episode: episode)] = Date(timeIntervalSince1970: TimeInterval(seconds))
            }
        }

        var parked: MDBListPendingShow {
            var episodes: [String: Int?] = [:]
            for (key, date) in dates {
                episodes[MDBListPendingShow.key(season: key.season, episode: key.episode)] =
                    Int(date.timeIntervalSince1970)
            }
            return MDBListPendingShow(episodes: episodes)
        }
    }

    /// Groups the flat episode rows by show, dropping rows without a TMDB show
    /// id or a watched timestamp.
    static func progressByShow(_ watched: [MDBListWatchedEpisode]) -> [Int: Progress] {
        var result: [Int: Progress] = [:]
        for item in watched {
            guard let tmdb = item.episode.show.ids.tmdb, let date = MDBListDates.parse(item.lastWatchedAt) else { continue }
            let key = SeasonEpisode(season: item.episode.season, episode: item.episode.number)
            var progress = result[tmdb] ?? Progress()
            progress.dates[key] = max(date, progress.dates[key] ?? .distantPast)
            result[tmdb] = progress
        }
        return result
    }

    private static func importEpisodes(
        _ watched: [MDBListWatchedEpisode],
        in context: ModelContext
    ) -> (marked: Int, queued: Int) {
        let shows = progressByShow(watched)
        guard !shows.isEmpty else { return (0, 0) }

        var pending = MDBListPendingWatchedStore.load()
        var pendingChanged = false
        var marked = 0
        var queued = 0

        for series in fetch(Series.self, tmdbIDs: Set(shows.keys), predicate: seriesTmdbIdPredicate, in: context) {
            guard let tmdb = series.tmdbId, let progress = shows[tmdb] else { continue }

            // Home's Recently Watched row queries this column; stamp it whether
            // or not the episodes exist yet, so an imported show surfaces now.
            if let newest = progress.newest, newest > (series.lastWatchedDate ?? .distantPast) {
                series.lastWatchedDate = newest
            }

            if series.episodes.isEmpty {
                pending[tmdb] = progress.parked
                pendingChanged = true
                queued += 1
            } else {
                marked += markEpisodes(of: series, using: progress)
                if pending[tmdb] != nil {
                    pending[tmdb] = nil
                    pendingChanged = true
                }
            }
        }

        if pendingChanged {
            MDBListPendingWatchedStore.save(pending)
        }
        return (marked, queued)
    }

    /// Applies parked MDBList progress to episodes that have just been fetched
    /// from the provider, and drops the entry once it has been used. Called
    /// from `Series.insertEpisodes`, the single place episodes ever materialize.
    @discardableResult
    static func applyPending(to series: Series) -> Int {
        guard let tmdb = series.tmdbId, !series.episodes.isEmpty,
              let parked = MDBListPendingWatchedStore.load()[tmdb] else { return 0 }

        let progress = Progress(parked: parked)
        let marked = markEpisodes(of: series, using: progress)
        if let newest = progress.newest, newest > (series.lastWatchedDate ?? .distantPast) {
            series.lastWatchedDate = newest
        }
        MDBListPendingWatchedStore.clear(tmdbID: tmdb)
        return marked
    }

    private static func markEpisodes(of series: Series, using progress: Progress) -> Int {
        var count = 0
        for episode in series.episodes where !episode.isWatched {
            let key = SeasonEpisode(season: episode.seasonNum, episode: episode.episodeNum)
            guard let date = progress.dates[key] else { continue }
            episode.isWatched = true
            episode.watchProgress = Double(episode.durationSecs ?? 0)
            episode.lastWatchedDate = date
            count += 1
        }
        return count
    }

    // MARK: - Candidate lookup

    /// The rows whose TMDB id is in `tmdbIDs`, fetched in `IN` batches kept well
    /// under SQLite's bound-variable limit, rather than by loading every row
    /// with any TMDB id — most of a large catalog.
    private static func fetch<Model: PersistentModel>(
        _: Model.Type,
        tmdbIDs: Set<Int>,
        predicate: (Set<Int>) -> Predicate<Model>,
        in context: ModelContext
    ) -> [Model] {
        let sorted = tmdbIDs.sorted()
        return stride(from: 0, to: sorted.count, by: 500).flatMap { start in
            let chunk = Set(sorted[start ..< min(start + 500, sorted.count)])
            return (try? context.fetch(FetchDescriptor<Model>(predicate: predicate(chunk)))) ?? []
        }
    }
}
