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

    /// The fetches one type is split into. Searching several playlists runs one
    /// per playlist so a single catalog can't spend the whole budget — plus one
    /// for rows no category claims, which a per-playlist fetch matches on
    /// category prefix would otherwise drop (m3u sources don't always supply a
    /// category).
    var scopes: [SearchScope] {
        guard playlistIDs.count > 1 else {
            return [SearchScope(
                query: query,
                playlistID: playlistIDs.first ?? "",
                restrictToPlaylist: !playlistIDs.isEmpty,
                excluded: excludedCategoryIDs
            )]
        }
        var scopes = playlistIDs.map {
            SearchScope(query: query, playlistID: $0, restrictToPlaylist: true, excluded: excludedCategoryIDs)
        }
        scopes.append(SearchScope(
            query: query, playlistID: "", restrictToPlaylist: false,
            excluded: excludedCategoryIDs, uncategorisedOnly: true
        ))
        return scopes
    }
}

/// Runs the bounded `localizedStandardContains` fetches on a background
/// `ModelContext` and returns only identifiers — never managed objects, which
/// can't cross actor boundaries.
nonisolated enum SearchFetcher {
    /// A matched row and the name it sorts under, kept together so the merge
    /// can re-sort what it picked without going back to the store.
    private struct Row {
        let id: PersistentIdentifier
        let name: String
    }

    static func fetch(container: ModelContainer, request: SearchRequest) -> SearchHits {
        let context = ModelContext(container)
        let scopes = request.scopes
        let limit = request.limit
        var hits = SearchHits()

        if request.wantMovies {
            hits.movies = merge(scopes.map {
                rows(in: context, predicate: searchMoviePredicate(scope: $0), name: \Movie.name, limit: limit)
            }, limit: limit)
        }

        if request.wantSeries {
            hits.series = merge(scopes.map {
                rows(in: context, predicate: searchSeriesPredicate(scope: $0), name: \Series.name, limit: limit)
            }, limit: limit)
        }

        if request.wantLive {
            hits.streams = merge(scopes.map {
                rows(in: context, predicate: searchLiveStreamPredicate(scope: $0), name: \LiveStream.name, limit: limit)
            }, limit: limit)
        }

        return hits
    }

    private static func rows<Model: PersistentModel>(
        in context: ModelContext,
        predicate: Predicate<Model>,
        name: KeyPath<Model, String>,
        limit: Int
    ) -> [Row] {
        var descriptor = FetchDescriptor<Model>(predicate: predicate, sortBy: [SortDescriptor(name)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map {
            Row(id: $0.persistentModelID, name: $0[keyPath: name])
        }
    }

    /// Spends the budget by taking one row from each list in turn, then puts
    /// what survived back in name order. The rotation is what keeps a playlist
    /// whose titles sort early from crowding the others out — and a playlist
    /// with only a couple of matches hands its unused share straight back. A
    /// single list is already ordered and bounded, so it passes through.
    private static func merge(_ lists: [[Row]], limit: Int) -> [PersistentIdentifier] {
        guard lists.count > 1 else { return (lists.first ?? []).map(\.id) }
        var picked: [Row] = []
        var seen = Set<PersistentIdentifier>()
        var index = 0
        while picked.count < limit {
            var advanced = false
            for list in lists where index < list.count {
                advanced = true
                guard seen.insert(list[index].id).inserted else { continue }
                picked.append(list[index])
                if picked.count == limit { break }
            }
            guard advanced, picked.count < limit else { break }
            index += 1
        }
        return picked
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.id)
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
    /// Matches only rows with no category at all. The other half of a
    /// per-playlist split: playlist scoping keys off the playlist UUID prefixed
    /// onto every category id, which uncategorised rows have nowhere to carry.
    var uncategorisedOnly = false

    /// The excluded ids as optionals, so a predicate can test the optional
    /// `categoryId` against them directly. Neither `?? ""` (a ternary) nor a
    /// nil-check plus force-unwrap survives SwiftData's SQL generation; matching
    /// a `Set<String?>` builds a plain `IN` clause — see `movieTmdbIdPredicate`.
    var excludedOptional: Set<String?> {
        Set(excluded.map(String?.some))
    }
}

/// Internal (not fileprivate) so the tests can run them against a SQLite store,
/// where predicate SQL is actually generated.
nonisolated func searchMoviePredicate(scope: SearchScope) -> Predicate<Movie> {
    let (query, playlistID) = (scope.query, scope.playlistID)
    let restrictToPlaylist = scope.restrictToPlaylist
    let uncategorisedOnly = scope.uncategorisedOnly
    let excluded = scope.excludedOptional
    let filtersCategories = !excluded.isEmpty
    return #Predicate { movie in
        movie.name.localizedStandardContains(query)
            && (!restrictToPlaylist || (movie.categoryId?.localizedStandardContains(playlistID) ?? false))
            && (!uncategorisedOnly || movie.categoryId == nil)
            && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
    }
}

nonisolated func searchSeriesPredicate(scope: SearchScope) -> Predicate<Series> {
    let (query, playlistID) = (scope.query, scope.playlistID)
    let restrictToPlaylist = scope.restrictToPlaylist
    let uncategorisedOnly = scope.uncategorisedOnly
    let excluded = scope.excludedOptional
    let filtersCategories = !excluded.isEmpty
    return #Predicate { series in
        series.name.localizedStandardContains(query)
            && (!restrictToPlaylist || (series.categoryId?.localizedStandardContains(playlistID) ?? false))
            && (!uncategorisedOnly || series.categoryId == nil)
            && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
    }
}

/// Live channels also carry their own Content Management visibility, so a
/// channel hidden individually is excluded here as well.
nonisolated func searchLiveStreamPredicate(scope: SearchScope) -> Predicate<LiveStream> {
    let (query, playlistID) = (scope.query, scope.playlistID)
    let restrictToPlaylist = scope.restrictToPlaylist
    let uncategorisedOnly = scope.uncategorisedOnly
    let excluded = scope.excludedOptional
    let filtersCategories = !excluded.isEmpty
    return #Predicate { stream in
        stream.name.localizedStandardContains(query)
            && stream.isHidden == false
            && (!restrictToPlaylist || (stream.categoryId?.localizedStandardContains(playlistID) ?? false))
            && (!uncategorisedOnly || stream.categoryId == nil)
            && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
    }
}
