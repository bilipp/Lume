//
//  IntentCatalogResolver.swift
//  Lume
//
//  Finds the channels, movies and series a Siri request names, for the App
//  Intents entity queries and the re-check in `perform()`. Pure: it reads the
//  catalog container on a fresh background context, never saves, never touches
//  the network, and hands back ids and spoken titles only — stream URLs and
//  credentials stay in the catalog.
//
//  The visibility rules are the app's own: only playlists the plan unlocks are
//  searched, and hidden or restricted categories plus individually hidden
//  channels never match (`SearchScope` / the search predicates, re-checked in
//  memory because favorites and recents are fetched outside them).
//

import Foundation
import SwiftData

nonisolated enum IntentContentKind: String {
    case channel
    case movie
    case series
}

/// One match, as Siri lists or speaks it. `id` is the playlist-prefixed catalog
/// id the widget deep links use.
nonisolated struct IntentCatalogItem: Hashable {
    let id: String
    let kind: IntentContentKind
    let displayTitle: String
    let playlistName: String
}

nonisolated struct IntentCatalogMatches {
    /// Best match first.
    let items: [IntentCatalogItem]
    /// The first two matches rank equally and neither was watched more
    /// recently, so Siri should ask rather than pick.
    let isAmbiguous: Bool
    /// How many matches from the top share the best rank — the ones Siri asks
    /// between when `isAmbiguous`.
    let leadingTieCount: Int

    static let empty = IntentCatalogMatches(items: [], isAmbiguous: false, leadingTieCount: 0)
}

nonisolated struct IntentCatalogResolver {
    let context: ModelContext
    /// The playlists the plan unlocks; nothing outside them is searched.
    let playlists: [Playlist]
    let restriction: ContentRestriction
    /// The in-effect playlist's `id.uuidString` (`[Playlist].activeID(for:)`).
    let activePlaylistID: String

    /// Rows fetched per playlist before ranking. The fetch is unsorted (a
    /// `sortBy:` defeats `fetchLimit`, see `SearchFetcher`), so this bounds the
    /// scan rather than choosing the best rows.
    private static let perPlaylistFetchLimit = 50
    /// Favorites plus recently watched considered per kind.
    private static let personalFetchLimit = 200

    // MARK: - Search

    func search(kind: IntentContentKind, name: String, limit: Int) -> IntentCatalogMatches {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return .empty }
        let interval = Perf.begin(.intentEntityResolve)
        defer { Perf.end(interval) }
        guard !playlists.isEmpty else { return .empty }

        let scopes = playlists.map {
            SearchScope(
                query: query,
                playlistID: $0.id.uuidString,
                restrictToPlaylist: true,
                excluded: restriction.excludedCategoryIDs
            )
        }
        var rows = Self.nameRows(kind: kind, scopes: scopes, in: context)
        rows += personalRows(kind: kind, matching: query)

        let normalizedQuery = Self.normalized(query)
        let ranked = rank(visible(unique(rows))) { row in
            Self.normalized(row.title) == normalizedQuery
        }
        let items = ranked.prefix(limit).map { item(for: $0.row, kind: kind) }
        let tieCount = ranked.prefix { candidate in
            candidate.score == ranked[0].score && candidate.row.lastWatched == ranked[0].row.lastWatched
        }.count
        return IntentCatalogMatches(
            items: items,
            isAmbiguous: tieCount > 1,
            leadingTieCount: min(tieCount, items.count)
        )
    }

    /// The titles behind `ids` the user can still reach, in the order asked
    /// for. An id that was deleted, hidden, restricted or plan-locked since
    /// Siri resolved it is left out.
    func items(ids: [String], kind: IntentContentKind) -> [IntentCatalogItem] {
        guard !ids.isEmpty, !playlists.isEmpty else { return [] }
        let rows: [Row] = switch kind {
        case .channel:
            Self.fetch(
                #Predicate<LiveStream> { ids.contains($0.id) && $0.isHidden == false },
                limit: ids.count, in: context
            ).map(Self.row)
        case .movie:
            Self.fetch(#Predicate<Movie> { ids.contains($0.id) }, limit: ids.count, in: context).map(Self.row)
        case .series:
            Self.fetch(#Predicate<Series> { ids.contains($0.id) }, limit: ids.count, in: context).map(Self.row)
        }
        let byID = Dictionary(visible(rows).map { ($0.id, $0) }) { first, _ in first }
        return ids.compactMap { byID[$0] }.map { item(for: $0, kind: kind) }
    }

    /// Favorites and recently watched titles of `kind`, most recently watched
    /// first, then favorites in the user's order.
    func suggested(kind: IntentContentKind, limit: Int) -> [IntentCatalogItem] {
        guard limit > 0, !playlists.isEmpty else { return [] }
        return visible(personalRows(kind: kind, matching: nil))
            .sorted(by: Self.personalOrder)
            .prefix(limit)
            .map { item(for: $0, kind: kind) }
    }

    // MARK: - Display titles

    /// Drops the provider's country or group tag from the front of a title —
    /// `DE | `, `UK: `, `[DE] `, `|UK| `, `(FR) `, `USA - ` — so Siri speaks the
    /// channel's own name. Only short upper-case tags are taken, so a title like
    /// `CSI: Miami` or `(500) Days of Summer` keeps its start; a title that is
    /// nothing but a tag is returned as is.
    static func displayTitle(_ name: String) -> String {
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = original
        for _ in 0 ..< 3 {
            guard let match = providerPrefix.firstMatch(
                in: title, range: NSRange(title.startIndex..., in: title)
            ), let range = Range(match.range, in: title) else { break }
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.isEmpty ? original : title
    }

    /// Case-, diacritic- and width-insensitive form with runs of whitespace
    /// collapsed, for the exact-name comparison.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // swiftlint:disable:next force_try
    private static let providerPrefix = try! NSRegularExpression(pattern: [
        #"^\[[A-Z][A-Z0-9 +&/.-]{0,10}\]\s*[|:-]?\s*"#,
        #"^\([A-Z]{2,4}\)\s*[|:-]?\s*"#,
        #"^\|[^|]{1,12}\|\s*"#,
        #"^[A-Z0-9][A-Z0-9 +&/.-]{0,9}?\s*[|│┃]\s*"#,
        #"^[A-Z]{2}\s*:\s*"#,
        #"^[A-Z]{2,3}\s+[-–]\s+"#
    ].joined(separator: "|"))

    // MARK: - Fetching

    private struct Row {
        let id: String
        /// The prefix-stripped `displayTitle`, worked out once per row.
        let title: String
        let categoryId: String?
        let isFavorite: Bool
        let favoriteOrder: Int?
        let lastWatched: Date?

        var isPersonal: Bool {
            isFavorite || lastWatched != nil
        }
    }

    private static func nameRows(kind: IntentContentKind, scopes: [SearchScope], in context: ModelContext) -> [Row] {
        scopes.flatMap { scope -> [Row] in
            switch kind {
            case .channel:
                fetch(searchLiveStreamPredicate(scope: scope), limit: perPlaylistFetchLimit, in: context).map(row)
            case .movie:
                fetch(searchMoviePredicate(scope: scope), limit: perPlaylistFetchLimit, in: context).map(row)
            case .series:
                fetch(searchSeriesPredicate(scope: scope), limit: perPlaylistFetchLimit, in: context).map(row)
            }
        }
    }

    /// Favorites and recents of `kind`, narrowed in SQLite to names containing
    /// `query` when there is one.
    private func personalRows(kind: IntentContentKind, matching query: String?) -> [Row] {
        let limit = Self.personalFetchLimit
        switch kind {
        case .channel:
            let predicate: Predicate<LiveStream>
            if let query {
                predicate = #Predicate<LiveStream> {
                    $0.isHidden == false && ($0.isFavorite || $0.lastWatchedDate != nil)
                        && $0.name.localizedStandardContains(query)
                }
            } else {
                predicate = #Predicate<LiveStream> {
                    $0.isHidden == false && ($0.isFavorite || $0.lastWatchedDate != nil)
                }
            }
            return Self.fetch(predicate, limit: limit, in: context).map(Self.row)
        case .movie:
            let predicate: Predicate<Movie>
            if let query {
                predicate = #Predicate<Movie> {
                    ($0.isFavorite || $0.lastWatchedDate != nil) && $0.name.localizedStandardContains(query)
                }
            } else {
                predicate = #Predicate<Movie> { $0.isFavorite || $0.lastWatchedDate != nil }
            }
            return Self.fetch(predicate, limit: limit, in: context).map(Self.row)
        case .series:
            let predicate: Predicate<Series>
            if let query {
                predicate = #Predicate<Series> {
                    ($0.isFavorite || $0.lastWatchedDate != nil) && $0.name.localizedStandardContains(query)
                }
            } else {
                predicate = #Predicate<Series> { $0.isFavorite || $0.lastWatchedDate != nil }
            }
            return Self.fetch(predicate, limit: limit, in: context).map(Self.row)
        }
    }

    private static func fetch<Model: PersistentModel>(
        _ predicate: Predicate<Model>,
        limit: Int,
        in context: ModelContext
    ) -> [Model] {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func row(_ stream: LiveStream) -> Row {
        Row(
            id: stream.id, title: displayTitle(stream.name), categoryId: stream.categoryId,
            isFavorite: stream.isFavorite, favoriteOrder: stream.favoriteOrder, lastWatched: stream.lastWatchedDate
        )
    }

    private static func row(_ movie: Movie) -> Row {
        Row(
            id: movie.id, title: displayTitle(movie.name), categoryId: movie.categoryId,
            isFavorite: movie.isFavorite, favoriteOrder: movie.favoriteOrder, lastWatched: movie.lastWatchedDate
        )
    }

    private static func row(_ series: Series) -> Row {
        Row(
            id: series.id, title: displayTitle(series.name), categoryId: series.categoryId,
            isFavorite: series.isFavorite, favoriteOrder: series.favoriteOrder, lastWatched: series.lastWatchedDate
        )
    }

    // MARK: - Filtering and ranking

    private func unique(_ rows: [Row]) -> [Row] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private func visible(_ rows: [Row]) -> [Row] {
        rows.filter { row in
            !restriction.hides(categoryID: row.categoryId) && playlists.owner(ofContentID: row.id) != nil
        }
    }

    /// Favorites and recents, then the active playlist, then an exact name
    /// match — as a score. Within a score the more recently watched leads;
    /// anything else that orders equal scores only keeps the list stable.
    private func rank(_ rows: [Row], isExact: (Row) -> Bool) -> [(row: Row, score: Int)] {
        let activePrefix = "\(activePlaylistID)-"
        return rows
            .map { row in
                var score = 0
                if row.isPersonal { score += 4 }
                if !activePlaylistID.isEmpty, row.id.hasPrefix(activePrefix) { score += 2 }
                if isExact(row) { score += 1 }
                return (row, score)
            }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : Self.personalOrder(lhs.row, rhs.row)
            }
    }

    private static func personalOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        let lhsWatched = lhs.lastWatched ?? .distantPast
        let rhsWatched = rhs.lastWatched ?? .distantPast
        if lhsWatched != rhsWatched { return lhsWatched > rhsWatched }
        let lhsOrder = lhs.isFavorite ? lhs.favoriteOrder ?? Int.max : Int.max
        let rhsOrder = rhs.isFavorite ? rhs.favoriteOrder ?? Int.max : Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }

    private func item(for row: Row, kind: IntentContentKind) -> IntentCatalogItem {
        IntentCatalogItem(
            id: row.id,
            kind: kind,
            displayTitle: row.title,
            playlistName: playlists.owner(ofContentID: row.id)?.name ?? ""
        )
    }
}
