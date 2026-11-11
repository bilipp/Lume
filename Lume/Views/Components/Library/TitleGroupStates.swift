//
//  TitleGroupStates.swift
//  Lume
//
//  The grouped user state of every movie and series a surface shows (Home,
//  Search, grids, library rows, detail rails), looked up once per load
//  (`TitleGroupStateLookup`), so no card fetches its own. Surfaces hand it to
//  their cards through the environment.
//

import SwiftData
import SwiftUI

struct TitleGroupStates: Equatable {
    /// Keyed by `titleGroupKey`. Movies and series are separate maps because a
    /// movie and a show can share a TMDB id, and so a key.
    var movies: [String: TitleGroupState] = [:]
    var series: [String: TitleGroupState] = [:]

    static let empty = TitleGroupStates()

    func state(of movie: Movie) -> TitleGroupState {
        TitleGroupStateLookup.state(of: movie, in: movies)
    }

    func state(of show: Series) -> TitleGroupState {
        TitleGroupStateLookup.state(of: show, in: series)
    }

    func isFavorite(_ item: HomeMediaItem) -> Bool {
        switch item {
        case let .movie(movie): state(of: movie).isFavorite
        case let .series(series): state(of: series).isFavorite
        case let .live(stream): stream.isFavorite
        }
    }

    /// Favorite toggle for a card showing this state: off clears every copy of
    /// the title, on writes only the row shown.
    func toggleFavorite(_ item: HomeMediaItem, in context: ModelContext) {
        switch item {
        case let .movie(movie):
            TitleGroupFavorites.toggle(movie, showsFavorite: state(of: movie).isFavorite, in: context)
        case let .series(series):
            TitleGroupFavorites.toggle(series, showsFavorite: state(of: series).isFavorite, in: context)
        case .live:
            break
        }
    }

    /// Re-reads the state of `item`'s title, after a write to it.
    mutating func reload(_ item: HomeMediaItem, in context: ModelContext) {
        guard let group = item.titleGroup else { return }
        switch group.kind {
        case .movie: movies.replace(keys: [group.key], with: TitleGroupStateLookup.movies(keys: [group.key], in: context))
        case .series: series.replace(keys: [group.key], with: TitleGroupStateLookup.series(keys: [group.key], in: context))
        }
    }

    static func load(for items: [HomeMediaItem], in context: ModelContext) -> TitleGroupStates {
        var request = Request()
        request.add(items)
        return load(for: request, in: context)
    }

    static func load(for request: Request, in context: ModelContext) -> TitleGroupStates {
        TitleGroupStates(
            movies: TitleGroupStateLookup.movies(keys: request.movieKeys, in: context),
            series: TitleGroupStateLookup.series(keys: request.seriesKeys, in: context)
        )
    }

    /// What a lookup covers.
    struct Request: Equatable {
        var movieKeys: Set<String> = []
        var seriesKeys: Set<String> = []

        mutating func add(_ items: some Sequence<HomeMediaItem>) {
            for group in items.lazy.compactMap(\.titleGroup) {
                switch group.kind {
                case .movie: movieKeys.insert(group.key)
                case .series: seriesKeys.insert(group.key)
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var titleGroupStates = TitleGroupStates.empty
}

extension HomeMediaItem {
    enum TitleKind: String {
        case movie, series
    }

    /// The `titleGroupKey` of this item's title and its kind (a movie and a
    /// show can share a key); nil for a channel or a row that is never grouped.
    var titleGroup: (kind: TitleKind, key: String)? {
        switch self {
        case let .movie(movie): movie.titleGroupKey.map { (.movie, $0) }
        case let .series(series): series.titleGroupKey.map { (.series, $0) }
        case .live: nil
        }
    }

    /// The title this item is a copy of, distinct across kinds.
    var titleGroupID: String? {
        titleGroup.map { "\($0.kind.rawValue)|\($0.key)" }
    }

    /// Resume fraction like `progress(seriesResume:)`, taken from the copy of
    /// the title watched last.
    func progress(seriesResume: [String: Double], groupStates: TitleGroupStates) -> Double? {
        switch self {
        case let .movie(movie):
            guard let last = groupStates.state(of: movie).lastWatched else { return nil }
            guard last.rowID != movie.id else { return progress(seriesResume: seriesResume) }
            // The sibling's own duration isn't in the lookup; a copy of the same
            // title runs as long as this one.
            guard let duration = movie.durationSecs, duration > 0, last.watchProgress > 0 else { return nil }
            return min(last.watchProgress / Double(duration), 1)
        case let .series(series):
            let last = groupStates.state(of: series).lastWatched?.rowID ?? series.id
            return seriesResume[last] ?? seriesResume[series.id]
        case .live:
            return nil
        }
    }
}
