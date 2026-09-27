//
//  SearchFetching.swift
//  Lume
//
//  The off-main fetch behind `SearchView` and the predicates it runs. Split out
//  of the view file to keep it within the size limit; the predicates are also
//  `internal` so the tests can run them against a SQLite store, where their SQL
//  is actually generated.
//

import SwiftData
import SwiftUI

// MARK: - Off-main search fetch

/// The matched rows' persistent identifiers, grouped by type. Plain value type
/// so it can cross back from the background fetch context.
nonisolated struct SearchHits {
    var movies: [PersistentIdentifier] = []
    var series: [PersistentIdentifier] = []
    var streams: [PersistentIdentifier] = []
}

/// The settled query and the per-type toggles, bundled so the off-main fetch
/// takes a single `Sendable` value.
nonisolated struct SearchRequest {
    let query: String
    /// The playlists to search, by `id.uuidString`. One id scopes the results
    /// to that playlist; several give each its own share of the budget; empty
    /// searches the store unscoped (there is no playlist yet).
    let playlistIDs: [String]
    let wantMovies: Bool
    let wantSeries: Bool
    let wantLive: Bool
    let excludedCategoryIDs: Set<String>
    /// Max rows per content type, across every playlist searched.
    let limit: Int

    /// The fetches one type is split into: one per playlist, so a single
    /// catalog can't spend the whole budget on its own. Scoping keys off the
    /// row's playlist-prefixed `id` (see `SearchScope.playlistIDPrefix`), so a
    /// playlist's uncategorised titles are inside its own scope.
    var scopes: [SearchScope] {
        guard !playlistIDs.isEmpty else {
            return [SearchScope(query: query, playlistID: "", restrictToPlaylist: false, excluded: excludedCategoryIDs)]
        }
        return playlistIDs.map {
            SearchScope(query: query, playlistID: $0, restrictToPlaylist: true, excluded: excludedCategoryIDs)
        }
    }
}

/// Runs the bounded `localizedStandardContains` fetches on a background
/// `ModelContext` and returns only identifiers — never managed objects, which
/// can't cross actor boundaries.
nonisolated enum SearchFetcher {
    static func fetch(container: ModelContainer, request: SearchRequest) -> SearchHits {
        let scopes = request.scopes
        let limit = request.limit
        let context = ModelContext(container)
        var hits = SearchHits()

        // None of the descriptors sorts. A `sortBy:` defeats `fetchLimit`:
        // with an ORDER BY, SQLite has to find *and sort* every match before it
        // can apply the LIMIT, so a bounded fetch still scanned the whole table
        // (263 ms for movies alone on a 179k-title catalog, 479 ms for the three
        // together) to show 50 rows. Without it the scan stops at the 50th hit.
        // The per-type name order the list has always shown is applied over the
        // hydrated rows instead — see `SearchView.assembleResults`.
        //
        // Searching several playlists runs one bounded fetch per playlist and
        // spends the budget by rotating between them (`interleaved`): one
        // catalog that happens to come first could otherwise fill every row and
        // leave the others looking unsearched, while a playlist with only a
        // couple of matches hands its unused share straight back.
        //
        // Each fetch is its own scan, so a superseded query burned the full
        // cost for a result nobody would read. `SearchView.localSearch`
        // forwards its cancellation into this task (`Task.detached` does not
        // inherit it), and `ids` checks it between scans. The partial hits
        // returned are discarded by the caller, which is cancelled too.
        if request.wantMovies {
            hits.movies = ids(in: context, scopes: scopes, limit: limit, predicate: searchMoviePredicate)
        }
        guard !Task.isCancelled else { return hits }

        if request.wantSeries {
            hits.series = ids(in: context, scopes: scopes, limit: limit, predicate: searchSeriesPredicate)
        }
        guard !Task.isCancelled else { return hits }

        if request.wantLive {
            hits.streams = ids(in: context, scopes: scopes, limit: limit, predicate: searchLiveStreamPredicate)
        }

        return hits
    }

    /// One bounded, unsorted fetch per scope, rotated into a single list of at
    /// most `limit` ids.
    private static func ids<Model: PersistentModel>(
        in context: ModelContext,
        scopes: [SearchScope],
        limit: Int,
        predicate: (SearchScope) -> Predicate<Model>
    ) -> [PersistentIdentifier] {
        var lists: [[PersistentIdentifier]] = []
        for scope in scopes {
            guard !Task.isCancelled else { break }
            var descriptor = FetchDescriptor<Model>(predicate: predicate(scope))
            descriptor.fetchLimit = limit
            lists.append(((try? context.fetch(descriptor)) ?? []).map(\.persistentModelID))
        }
        return interleaved(lists, limit: limit)
    }
}

// MARK: - Search predicates

/// What a search fetch is scoped to: the query, the optional single-playlist
/// restriction and the categories hidden from the current viewer.
nonisolated struct SearchScope {
    let query: String
    let playlistID: String
    let restrictToPlaylist: Bool
    let excluded: Set<String>

    /// The excluded ids as optionals, so a predicate can test the optional
    /// `categoryId` against them directly. Neither `?? ""` (a ternary) nor a
    /// nil-check plus force-unwrap survives SwiftData's SQL generation; matching
    /// a `Set<String?>` builds a plain `IN` clause — see `movieTmdbIdPredicate`.
    var excludedOptional: Set<String?> {
        Set(excluded.map(String?.some))
    }

    /// The playlist restriction as an id prefix. Every catalog row's id is
    /// `"<playlist uuid>-<kind>-<provider id>"` (see `ContentSyncManager`), so a
    /// prefix test on the row's own `id` scopes a fetch to one playlist — and
    /// `id` is `@Attribute(.unique)`, i.e. indexed, the same range seek
    /// `PlaylistDeletion` scopes with. The separator is part of the prefix so
    /// the match can't run past the uuid into a longer id.
    var playlistIDPrefix: String {
        "\(playlistID)-"
    }
}

/// Internal (not fileprivate) so the tests can run them against a SQLite store,
/// where predicate SQL is actually generated.
///
/// The playlist scope is emitted only when it applies rather than being folded
/// into an `||` with a captured flag: it used to read
/// `categoryId?.localizedStandardContains(playlistID)`, a second
/// `NSCoreDataStringSearch` per row — a full substring search used as a prefix
/// test, and as expensive as the name match it was paired with.
nonisolated func searchMoviePredicate(scope: SearchScope) -> Predicate<Movie> {
    let query = scope.query
    let excluded = scope.excludedOptional
    let filtersCategories = !excluded.isEmpty
    guard scope.restrictToPlaylist else {
        return #Predicate { movie in
            movie.name.localizedStandardContains(query)
                && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
        }
    }
    let prefix = scope.playlistIDPrefix
    return #Predicate { movie in
        movie.name.localizedStandardContains(query)
            && movie.id.starts(with: prefix)
            && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
    }
}

nonisolated func searchSeriesPredicate(scope: SearchScope) -> Predicate<Series> {
    let query = scope.query
    let excluded = scope.excludedOptional
    let filtersCategories = !excluded.isEmpty
    guard scope.restrictToPlaylist else {
        return #Predicate { series in
            series.name.localizedStandardContains(query)
                && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
        }
    }
    let prefix = scope.playlistIDPrefix
    return #Predicate { series in
        series.name.localizedStandardContains(query)
            && series.id.starts(with: prefix)
            && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
    }
}

/// Live channels also carry their own Content Management visibility, so a
/// channel hidden individually is excluded here as well.
nonisolated func searchLiveStreamPredicate(scope: SearchScope) -> Predicate<LiveStream> {
    let query = scope.query
    let excluded = scope.excludedOptional
    let filtersCategories = !excluded.isEmpty
    guard scope.restrictToPlaylist else {
        return #Predicate { stream in
            stream.name.localizedStandardContains(query)
                && stream.isHidden == false
                && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
        }
    }
    let prefix = scope.playlistIDPrefix
    return #Predicate { stream in
        stream.name.localizedStandardContains(query)
            && stream.isHidden == false
            && stream.id.starts(with: prefix)
            && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
    }
}

// MARK: - Interleaving

/// Spends `limit` by taking one element from each list in turn, preserving each
/// list's own order and dropping repeats. Used for hits from several Stalker
/// portals, where each returns its own relevance ranking and concatenating them
/// would bury a second portal's best match under everything the first had to
/// say, and for the local pass's per-playlist fetches, where one catalog would
/// otherwise fill the whole budget. Lists shorter than the rest simply drop out
/// of the rotation.
nonisolated func interleaved<Element: Hashable>(_ lists: [[Element]], limit: Int) -> [Element] {
    guard lists.count > 1 else { return Array((lists.first ?? []).prefix(limit)) }
    var merged: [Element] = []
    var seen = Set<Element>()
    var index = 0
    while merged.count < limit {
        var advanced = false
        for list in lists where index < list.count {
            advanced = true
            guard seen.insert(list[index]).inserted else { continue }
            merged.append(list[index])
            if merged.count == limit { break }
        }
        guard advanced, merged.count < limit else { break }
        index += 1
    }
    return merged
}
