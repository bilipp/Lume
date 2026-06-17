//
//  HomeMediaItem.swift
//  Lume
//
//  A type-erased wrapper over the three playable content kinds so a single
//  horizontal row (see HomeRows) can present movies, series and live channels
//  together.
//

import Foundation

enum HomeMediaItem: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)
    case live(LiveStream)

    var id: String {
        switch self {
        case let .movie(movie): "movie-\(movie.id)"
        case let .series(series): "series-\(series.id)"
        case let .live(stream): "live-\(stream.id)"
        }
    }

    var title: String {
        switch self {
        case let .movie(movie): movie.name
        case let .series(series): series.name
        case let .live(stream): stream.name
        }
    }

    var imageURL: URL? {
        switch self {
        case let .movie(movie): URL(string: movie.streamIcon ?? "")
        case let .series(series): URL(string: series.cover ?? "")
        case let .live(stream): URL(string: stream.streamIcon ?? "")
        }
    }

    var lastWatchedDate: Date? {
        switch self {
        case let .movie(movie): movie.lastWatchedDate
        case let .series(series): series.lastWatchedDate
        case let .live(stream): stream.lastWatchedDate
        }
    }

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// Resume fraction for partially-watched movies or series (0...1), otherwise nil.
    var progress: Double? {
        switch self {
        case let .movie(movie):
            guard let duration = movie.durationSecs, duration > 0,
                  movie.watchProgress > 0, !movie.isWatched else { return nil }
            return min(movie.watchProgress / Double(duration), 1)
        case let .series(series):
            let inProgressEpisodes = series.episodes
                .filter { $0.watchProgress > 0 && !$0.isWatched }
                .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            guard let activeEpisode = inProgressEpisodes.first,
                  let duration = activeEpisode.durationSecs, duration > 0 else { return nil }
            return min(activeEpisode.watchProgress / Double(duration), 1)
        case .live:
            return nil
        }
    }
}
