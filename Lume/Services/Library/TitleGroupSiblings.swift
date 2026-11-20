//
//  TitleGroupSiblings.swift
//  Lume
//
//  Turning user state off for a grouped title. A card shows a title as
//  favorite or watched when any copy is, so switching that
//  off has to clear every copy or the card would keep showing it. Switching on
//  writes only the row on screen.
//

import Foundation
import SwiftData

nonisolated enum TitleGroupSiblings {
    /// Every catalog row of `row`'s title in any playlist, `row` included:
    /// rows with its `tmdbId` and rows with its `titleGroupKey`.
    static func rows<Row: TitleSiblingRow>(of row: Row, in context: ModelContext) -> [Row] {
        [row] + others(of: row, in: context)
    }

    /// The rows `rows(of:in:)` returns other than `row`, in one fetch.
    static func others<Row: TitleSiblingRow>(of row: Row, in context: ModelContext) -> [Row] {
        switch (row.tmdbId, row.titleGroupKey) {
        case let (tmdbId?, key?): Row.rows(sharing: tmdbId, orGroupKey: key, except: row.id, in: context)
        case let (tmdbId?, nil): Row.rows(sharing: tmdbId, except: row.id, in: context)
        case let (nil, key?): Row.rows(groupKey: key, except: row.id, in: context)
        case (nil, nil): []
        }
    }

    // MARK: Toggle off

    // Each returns the rows it changed and leaves saving to the caller, like
    // `MediaFavorites.clearFavoriteState`.

    /// Unfavorites every copy. Clears the watchlist stamp and favorites order
    /// with the flag, as `MediaFavorites.clearFavoriteState` does: either left
    /// behind keeps the synced record alive.
    @discardableResult
    static func unfavorite<Row: TitleSiblingRow & WatchlistRow>(_ row: Row, in context: ModelContext) -> [Row] {
        rows(of: row, in: context).filter { clearFavorite($0) }
    }

    /// Marks every copy unwatched. Progress stays, as it does when the detail
    /// screen unmarks a single movie.
    @discardableResult
    static func markUnwatched(_ movie: Movie, in context: ModelContext) -> [Movie] {
        rows(of: movie, in: context).filter { row in
            guard row.isWatched else { return false }
            row.isWatched = false
            return true
        }
    }

    /// Drops every copy from Recently Watched, or only `row` when titles are
    /// not grouped: grouped, an older copy would otherwise take the card's place.
    @discardableResult
    static func clearLastWatched<Row: TitleSiblingRow & LastWatchedRow>(
        _ row: Row,
        grouped: Bool,
        in context: ModelContext
    ) -> [Row] {
        (grouped ? rows(of: row, in: context) : [row]).filter { row in
            guard row.lastWatchedDate != nil else { return false }
            row.lastWatchedDate = nil
            return true
        }
    }
}

private nonisolated extension TitleGroupSiblings {
    static func clearFavorite(_ row: some WatchlistRow) -> Bool {
        guard row.isFavorite || row.favoriteOrder != nil || row.addedToWatchlistDate != nil else { return false }
        if row.isFavorite { row.isFavorite = false }
        if row.favoriteOrder != nil { row.favoriteOrder = nil }
        if row.addedToWatchlistDate != nil { row.addedToWatchlistDate = nil }
        return true
    }
}

/// `WatchlistFavoritable` is main-actor isolated; the sibling writes run on any
/// context.
nonisolated protocol WatchlistRow: AnyObject {
    var isFavorite: Bool { get set }
    var favoriteOrder: Int? { get set }
    var addedToWatchlistDate: Date? { get set }
}

nonisolated extension Movie: WatchlistRow {}
nonisolated extension Series: WatchlistRow {}

nonisolated protocol LastWatchedRow: AnyObject {
    var lastWatchedDate: Date? { get set }
}

nonisolated extension Movie: LastWatchedRow {}
nonisolated extension Series: LastWatchedRow {}

/// The fetches that find the other copies of a movie or series title.
nonisolated protocol TitleSiblingRow: TitleGroupedRow, PersistentModel {
    /// The tab whose scope members this kind of row belongs to.
    static var playlistTab: PlaylistTab { get }
    static func row(id: String, in context: ModelContext) -> Self?
    /// Rows other than `id` with TMDB id `tmdbId`.
    static func rows(sharing tmdbId: Int, except id: String, in context: ModelContext) -> [Self]
    /// Rows other than `id` with `titleGroupKey` `groupKey`.
    static func rows(groupKey: String, except id: String, in context: ModelContext) -> [Self]
    /// Rows other than `id` with TMDB id `tmdbId` or `titleGroupKey` `groupKey`.
    static func rows(sharing tmdbId: Int, orGroupKey groupKey: String, except id: String, in context: ModelContext) -> [Self]
}

nonisolated extension Movie: TitleSiblingRow {
    static var playlistTab: PlaylistTab {
        .movies
    }

    static func row(id: String, in context: ModelContext) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func rows(sharing tmdbId: Int, except id: String, in context: ModelContext) -> [Movie] {
        let value: Int? = tmdbId
        return (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
            $0.tmdbId == value && $0.id != id
        }))) ?? []
    }

    static func rows(groupKey: String, except id: String, in context: ModelContext) -> [Movie] {
        let value: String? = groupKey
        return (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
            $0.titleGroupKey == value && $0.id != id
        }))) ?? []
    }

    static func rows(sharing tmdbId: Int, orGroupKey groupKey: String, except id: String, in context: ModelContext) -> [Movie] {
        let tmdbValue: Int? = tmdbId
        let keyValue: String? = groupKey
        return (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
            ($0.tmdbId == tmdbValue || $0.titleGroupKey == keyValue) && $0.id != id
        }))) ?? []
    }
}

nonisolated extension Series: TitleSiblingRow {
    static var playlistTab: PlaylistTab {
        .series
    }

    static func row(id: String, in context: ModelContext) -> Series? {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func rows(sharing tmdbId: Int, except id: String, in context: ModelContext) -> [Series] {
        let value: Int? = tmdbId
        return (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate {
            $0.tmdbId == value && $0.id != id
        }))) ?? []
    }

    static func rows(groupKey: String, except id: String, in context: ModelContext) -> [Series] {
        let value: String? = groupKey
        return (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate {
            $0.titleGroupKey == value && $0.id != id
        }))) ?? []
    }

    static func rows(sharing tmdbId: Int, orGroupKey groupKey: String, except id: String, in context: ModelContext) -> [Series] {
        let tmdbValue: Int? = tmdbId
        let keyValue: String? = groupKey
        return (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate {
            ($0.tmdbId == tmdbValue || $0.titleGroupKey == keyValue) && $0.id != id
        }))) ?? []
    }
}
