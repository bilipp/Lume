//
//  HomeDerivedContent.swift
//  Lume
//
//  Presence and emptiness helpers for Home rails, avoiding sorting and
//  allocating full item collections during empty-state evaluations.
//

import Foundation

struct HomeDerivedScope {
    let playlistPrefix: String?
    let restriction: ContentRestriction
}

enum HomeDerivedContent {
    static func isItemVisible(
        id: String,
        categoryId: String?,
        scope: HomeDerivedScope
    ) -> Bool {
        if let prefix = scope.playlistPrefix, !id.hasPrefix(prefix) {
            return false
        }
        let excluded = scope.restriction.excludedCategoryIDs
        return excluded.isEmpty || !excluded.contains(categoryId ?? "")
    }

    static func hasRecentlyWatched(
        movies: [Movie],
        series: [Series],
        streams: [LiveStream],
        includeLiveTV: Bool,
        scope: HomeDerivedScope
    ) -> Bool {
        if movies.contains(where: { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }) {
            return true
        }
        if series.contains(where: { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }) {
            return true
        }
        if includeLiveTV, streams.contains(where: { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }) {
            return true
        }
        return false
    }

    static func hasFavorites(
        movies: [Movie],
        series: [Series],
        streams: [LiveStream],
        scope: HomeDerivedScope
    ) -> Bool {
        if movies.contains(where: { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }) {
            return true
        }
        if series.contains(where: { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }) {
            return true
        }
        if streams.contains(where: { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }) {
            return true
        }
        return false
    }

    static func recentlyWatched(
        movies: [Movie],
        series: [Series],
        streams: [LiveStream],
        includeLiveTV: Bool,
        scope: HomeDerivedScope
    ) -> [HomeMediaItem] {
        var items = movies.filter { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }.map(HomeMediaItem.movie)
            + series.filter { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }.map(HomeMediaItem.series)
        if includeLiveTV {
            items += streams.filter { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }.map(HomeMediaItem.live)
        }
        return items
            .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            .prefix(10)
            .map(\.self)
    }

    static func favorites(
        movies: [Movie],
        series: [Series],
        streams: [LiveStream],
        scope: HomeDerivedScope
    ) -> [HomeMediaItem] {
        let visibleMovies = movies.filter { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }
        let visibleSeries = series.filter { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }
        let visibleStreams = streams.filter { isItemVisible(id: $0.id, categoryId: $0.categoryId, scope: scope) }

        // Interleave the three types by the cross-type `favoriteOrder` set in
        // Content Management → Favorites, so a movie placed above a channel shows
        // above it here too. Items never reordered (nil) fall back to a stable
        // type/name grouping (channels, movies, then series) — the same fallback
        // the favorites manager uses.
        let entries: [(order: Int?, rank: Int, name: String, item: HomeMediaItem)] =
            visibleStreams.map { ($0.favoriteOrder, 0, $0.name, HomeMediaItem.live($0)) }
                + visibleMovies.map { ($0.favoriteOrder, 1, $0.name, HomeMediaItem.movie($0)) }
                + visibleSeries.map { ($0.favoriteOrder, 2, $0.name, HomeMediaItem.series($0)) }

        return entries
            .sorted { ($0.order ?? Int.max, $0.rank, $0.name) < ($1.order ?? Int.max, $1.rank, $1.name) }
            .map(\.item)
    }
}
