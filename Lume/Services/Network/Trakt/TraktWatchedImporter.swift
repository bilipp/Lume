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

import Foundation
import SwiftData

/// The outcome of an import, surfaced in the settings UI.
struct TraktImportSummary: Equatable {
    var moviesMarked = 0
    var episodesMarked = 0
    var failed = false

    static let failure = TraktImportSummary(failed: true)

    var markedNothing: Bool {
        !failed && moviesMarked == 0 && episodesMarked == 0
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
        let episodesMarked = importShows(shows, in: context)

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                return TraktImportSummary(moviesMarked: moviesMarked, episodesMarked: episodesMarked, failed: true)
            }
        }
        return TraktImportSummary(moviesMarked: moviesMarked, episodesMarked: episodesMarked, failed: false)
    }

    // MARK: - Movies

    private static func importMovies(_ watched: [TraktWatchedMovie], in context: ModelContext) -> Int {
        var watchedIDs = Set<Int>()
        var dates: [Int: Date] = [:]
        for item in watched {
            guard let tmdb = item.movie.ids.tmdb else { continue }
            watchedIDs.insert(tmdb)
            if let date = parse(item.lastWatchedAt) { dates[tmdb] = date }
        }
        guard !watchedIDs.isEmpty else { return 0 }

        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId != nil })
        let candidates = (try? context.fetch(descriptor)) ?? []

        var count = 0
        for movie in candidates where !movie.isWatched {
            guard let tmdb = movie.tmdbId, watchedIDs.contains(tmdb) else { continue }
            movie.isWatched = true
            movie.watchProgress = Double(movie.durationSecs ?? 0)
            if let date = dates[tmdb] { movie.lastWatchedDate = date }
            count += 1
        }
        return count
    }

    // MARK: - Shows

    private struct SeasonEpisode: Hashable {
        let season: Int
        let episode: Int
    }

    private static func importShows(_ watched: [TraktWatchedShow], in context: ModelContext) -> Int {
        var showsByTMDB: [Int: TraktWatchedShow] = [:]
        for show in watched {
            guard let tmdb = show.show.ids.tmdb else { continue }
            showsByTMDB[tmdb] = show
        }
        guard !showsByTMDB.isEmpty else { return 0 }

        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId != nil })
        let candidates = (try? context.fetch(descriptor)) ?? []

        var count = 0
        for series in candidates {
            guard let tmdb = series.tmdbId, let show = showsByTMDB[tmdb] else { continue }
            count += markEpisodes(of: series, against: show)
        }
        return count
    }

    /// Marks the episodes of `series` that `show` reports as watched, returning
    /// how many changed.
    private static func markEpisodes(of series: Series, against show: TraktWatchedShow) -> Int {
        var watchedKeys = Set<SeasonEpisode>()
        var dates: [SeasonEpisode: Date] = [:]
        for season in show.seasons {
            for episode in season.episodes {
                let key = SeasonEpisode(season: season.number, episode: episode.number)
                watchedKeys.insert(key)
                if let date = parse(episode.lastWatchedAt) { dates[key] = date }
            }
        }

        var count = 0
        for episode in series.episodes where !episode.isWatched {
            let key = SeasonEpisode(season: episode.seasonNum, episode: episode.episodeNum)
            guard watchedKeys.contains(key) else { continue }
            episode.isWatched = true
            episode.watchProgress = Double(episode.durationSecs ?? 0)
            if let date = dates[key] { episode.lastWatchedDate = date }
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
