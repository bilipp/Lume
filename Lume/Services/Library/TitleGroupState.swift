//
//  TitleGroupState.swift
//  Lume
//
//  The user state a grouped card or detail screen shows: favorite, watched,
//  watchlist and progress hold if any copy of the title has them. State stays
//  stored per catalog row; this only reads it, for a whole page of titles in
//  one fetch per model.
//

import Foundation
import SwiftData

/// What one title shows across all of its copies.
nonisolated struct TitleGroupState: Equatable {
    /// The most recently watched copy, the one Resume reopens.
    struct LastWatched: Equatable {
        let rowID: String
        /// Seconds into a movie; always 0 for a series, whose progress lives on
        /// its episodes.
        let watchProgress: Double
        let date: Date?
    }

    var isFavorite = false
    var isWatched = false
    var isOnWatchlist = false
    var lastWatched: LastWatched?

    static let empty = TitleGroupState()
}

nonisolated extension [String: TitleGroupState] {
    /// Replaces the entries for `keys` with `fresh`, dropping a key `fresh`
    /// no longer has state for.
    mutating func replace(keys: some Sequence<String>, with fresh: [String: TitleGroupState]) {
        for key in keys {
            self[key] = fresh[key]
        }
    }
}

nonisolated enum TitleGroupStateLookup {
    /// SQLite caps bound parameters per statement; a page never comes close,
    /// a whole-library caller would.
    private static let keysPerFetch = 500

    /// Group state for every key in `keys` that some movie row has state for.
    /// A key missing from the result has none.
    static func movies(keys: some Collection<String>, in context: ModelContext) -> [String: TitleGroupState] {
        lookup(keys: keys, in: context) { chunk in
            let inGroups = #Predicate<Movie> { chunk.contains($0.titleGroupKey) }
            let flagged = #Predicate<Movie> { $0.isFavorite == true || $0.isWatched == true }
            let started = #Predicate<Movie> { $0.addedToWatchlistDate != nil || $0.watchProgress > 0 }
            let predicate = #Predicate<Movie> { inGroups.evaluate($0) && (flagged.evaluate($0) || started.evaluate($0)) }
            var descriptor = FetchDescriptor<Movie>(predicate: predicate)
            descriptor.propertiesToFetch = [
                \Movie.id,
                \Movie.titleGroupKey,
                \Movie.isFavorite,
                \Movie.isWatched,
                \Movie.addedToWatchlistDate,
                \Movie.watchProgress,
                \Movie.lastWatchedDate
            ]
            return descriptor
        }
    }

    /// Group state for every key in `keys` that some series row has state for.
    static func series(keys: some Collection<String>, in context: ModelContext) -> [String: TitleGroupState] {
        lookup(keys: keys, in: context) { chunk in
            let predicate = #Predicate<Series> { series in
                chunk.contains(series.titleGroupKey) && (
                    series.isFavorite == true
                        || series.addedToWatchlistDate != nil
                        || series.lastWatchedDate != nil
                )
            }
            var descriptor = FetchDescriptor<Series>(predicate: predicate)
            descriptor.propertiesToFetch = [
                \Series.id,
                \Series.titleGroupKey,
                \Series.isFavorite,
                \Series.addedToWatchlistDate,
                \Series.lastWatchedDate
            ]
            return descriptor
        }
    }

    static func states<Row: TitleGroupStateRow>(of rows: [Row], in context: ModelContext) -> [String: TitleGroupState] {
        Row.groupStates(keys: rows.compactMap(\.titleGroupKey), in: context)
    }

    /// `row`'s own state joined with its title's. A row without a key is
    /// never grouped, so it shows only its own.
    static func state(of row: some TitleGroupStateRow, in states: [String: TitleGroupState]) -> TitleGroupState {
        var state = row.titleGroupKey.flatMap { states[$0] } ?? .empty
        row.merge(into: &state)
        return state
    }

    /// Runs `descriptor` per chunk of `keys` and merges each row it returns
    /// into its key's state.
    private static func lookup(
        keys: some Collection<String>,
        in context: ModelContext,
        descriptor: (Set<String?>) -> FetchDescriptor<some TitleGroupStateRow>
    ) -> [String: TitleGroupState] {
        var states: [String: TitleGroupState] = [:]
        for chunk in chunks(of: keys) {
            for row in (try? context.fetch(descriptor(chunk))) ?? [] {
                guard let key = row.titleGroupKey else { continue }
                row.merge(into: &states[key, default: .empty])
            }
        }
        return states
    }

    /// `keys` as `String?` (the stored column is optional, and `contains` on
    /// an optional set is the form SwiftData turns into a plain `IN`).
    private static func chunks(of keys: some Collection<String>) -> [Set<String?>] {
        let unique = Array(Set(keys))
        return stride(from: 0, to: unique.count, by: keysPerFetch).map { start in
            Set(unique[start ..< min(start + keysPerFetch, unique.count)].map(Optional.some))
        }
    }
}

/// A movie or series row, with what it adds to its title's state.
nonisolated protocol TitleGroupStateRow: TitleGroupedRow {
    func merge(into state: inout TitleGroupState)
    /// ``TitleGroupStateLookup`` for this kind of row.
    static func groupStates(keys: some Collection<String>, in context: ModelContext) -> [String: TitleGroupState]
}

nonisolated extension Movie: TitleGroupStateRow {
    func merge(into state: inout TitleGroupState) {
        state.isFavorite = state.isFavorite || isFavorite
        state.isWatched = state.isWatched || isWatched
        state.isOnWatchlist = state.isOnWatchlist || addedToWatchlistDate != nil
        guard watchProgress > 0 else { return }
        state.considerLastWatched(TitleGroupState.LastWatched(rowID: id, watchProgress: watchProgress, date: lastWatchedDate))
    }

    static func groupStates(keys: some Collection<String>, in context: ModelContext) -> [String: TitleGroupState] {
        TitleGroupStateLookup.movies(keys: keys, in: context)
    }
}

nonisolated extension Series: TitleGroupStateRow {
    func merge(into state: inout TitleGroupState) {
        state.isFavorite = state.isFavorite || isFavorite
        state.isOnWatchlist = state.isOnWatchlist || addedToWatchlistDate != nil
        guard lastWatchedDate != nil else { return }
        state.considerLastWatched(TitleGroupState.LastWatched(rowID: id, watchProgress: 0, date: lastWatchedDate))
    }

    static func groupStates(keys: some Collection<String>, in context: ModelContext) -> [String: TitleGroupState] {
        TitleGroupStateLookup.series(keys: keys, in: context)
    }
}

private nonisolated extension TitleGroupState {
    /// Latest date wins and an undated copy loses to any dated one. Equal dates
    /// fall to the lower row id so the answer doesn't depend on fetch order. A
    /// copy already held is replaced, so the live row beats a stale lookup.
    mutating func considerLastWatched(_ candidate: LastWatched) {
        guard let current = lastWatched, current.rowID != candidate.rowID else {
            lastWatched = candidate
            return
        }
        let currentDate = current.date ?? .distantPast
        let candidateDate = candidate.date ?? .distantPast
        if candidateDate > currentDate || (candidateDate == currentDate && candidate.rowID < current.rowID) {
            lastWatched = candidate
        }
    }
}
