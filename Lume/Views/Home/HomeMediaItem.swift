//
//  HomeMediaItem.swift
//  Lume
//
//  A type-erased wrapper over the three playable content kinds so a single
//  horizontal row (see HomeRows) can present movies, series and live channels
//  together, plus the resume-progress lookup those rows read from.
//

import Foundation
import SwiftData

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

    /// Resume fraction for partially-watched movies or series (0...1), otherwise
    /// nil. A movie carries its own progress, so it is read straight off the row;
    /// a series' lives on its episodes and is looked up in `seriesResume`, the
    /// map `SeriesResumeLoader` builds once for the whole screen. This is called
    /// per card per body pass, and deriving the series case here meant faulting
    /// the entire `episodes` relationship each time — see the loader below.
    func progress(seriesResume: [String: Double]) -> Double? {
        switch self {
        case let .movie(movie):
            guard let duration = movie.durationSecs, duration > 0,
                  movie.watchProgress > 0, !movie.isWatched else { return nil }
            return min(movie.watchProgress / Double(duration), 1)
        case let .series(series):
            return seriesResume[series.id]
        case .live:
            return nil
        }
    }
}

// MARK: - Series resume lookup

/// Builds the resume fraction of every partially-watched series in one indexed
/// fetch, off the main thread, keyed by series id.
///
/// `HomeMediaItem.progress` used to derive this per card, from `body`, by
/// filtering and sorting `series.episodes` — which faults the whole to-many
/// relationship. A launch trace on a 47,930-series playlist counted 2,663
/// `ZEPISODE WHERE ZSERIES = ?` faults from that accessor alone, and reading
/// every episode's watch state from a view body also made Home observe all of
/// them, so any episode write re-rendered the screen. This is the same hoist
/// `ChannelEPGLoader` performs for the Live TV cards: one bounded fetch for the
/// whole screen, plain values out.
enum SeriesResumeLoader {
    nonisolated static func load(container: ModelContainer) -> [String: Double] {
        let context = ModelContext(container)
        // Scoped by watch state, not by the series on screen: `watchProgress`
        // and `isWatched` are both indexed on `Episode`, so this seeks the
        // handful of in-progress rows however large the episode table is.
        // Prefetching `series` resolves the owning show in the same round trip
        // instead of one to-one fault per episode.
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.watchProgress > 0 && $0.isWatched == false }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.series]
        guard let episodes = try? context.fetch(descriptor) else { return [:] }

        var newest: [String: Date] = [:]
        var resume: [String: Double] = [:]
        for episode in episodes {
            guard let seriesId = episode.series?.id else { continue }
            // The most recently watched in-progress episode decides the bar —
            // including deciding there is none, when it carries no duration to
            // divide by. That is what the per-card accessor did: it sorted by
            // `lastWatchedDate` descending and gave up on the first entry, so an
            // older episode must not stand in for it.
            let watched = episode.lastWatchedDate ?? .distantPast
            if let seen = newest[seriesId], seen >= watched { continue }
            newest[seriesId] = watched
            if let duration = episode.durationSecs, duration > 0 {
                resume[seriesId] = min(episode.watchProgress / Double(duration), 1)
            } else {
                resume.removeValue(forKey: seriesId)
            }
        }
        return resume
    }
}
