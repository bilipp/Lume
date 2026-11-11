//
//  TitleGrouping.swift
//  Lume
//
//  One card per title on the surfaces that mix categories and playlists (Home,
//  Search, Genre grids, For You, Library rows, detail rails, Continue
//  Watching). Rows are grouped by `titleGroupKey` in memory; the catalog keeps
//  every copy. Category grids use the stored primary flag instead
//  (`CategoryGridQuery`).
//

import Foundation

nonisolated enum TitleGrouping {
    /// How many raw rows a bounded grouped fetch reads per title it shows:
    /// copies of one title collapse after the fetch.
    static let overFetch = 3

    /// The raw fetch limit that leaves `limit` titles once copies collapse.
    static func fetchLimit(_ limit: Int, grouped: Bool) -> Int {
        limit * (grouped ? overFetch : 1)
    }

    /// Which copy of a title represents it: the copy from the highest-priority
    /// scope member, then the best `VariantTags` rank, then the lowest row id.
    struct Ranking {
        let matcher: CatalogScope.Matcher
        let preferredLanguages: [String]
        /// Category id to name, the language fallback for untagged titles.
        let categoryNames: [String: String]

        init(
            scope: CatalogScope,
            preferredLanguages: [String] = PlayerLanguageOptions.load().preferredAudioLanguages,
            categoryNames: [String: String] = [:]
        ) {
            self.init(
                matcher: CatalogScope.Matcher(scope),
                preferredLanguages: preferredLanguages,
                categoryNames: categoryNames
            )
        }

        init(matcher: CatalogScope.Matcher, preferredLanguages: [String], categoryNames: [String: String] = [:]) {
            self.matcher = matcher
            self.preferredLanguages = preferredLanguages
            self.categoryNames = categoryNames
        }

        /// Ungrouped, the highest-priority member's first copy, as before
        /// grouping.
        func best<Row: TitleGroupedRow>(of rows: [Row], grouped: Bool) -> Row {
            if grouped { return best(of: rows) }
            return rows.min { matcher.memberRank(of: $0.id) < matcher.memberRank(of: $1.id) } ?? rows[0]
        }

        func best<Row: TitleGroupedRow>(of rows: [Row]) -> Row {
            guard rows.count > 1 else { return rows[0] }
            var bestRow = rows[0]
            var bestKey = sortKey(bestRow)
            for row in rows.dropFirst() {
                let key = sortKey(row)
                if key.precedes(bestKey) || (!bestKey.precedes(key) && row.id < bestRow.id) {
                    bestRow = row
                    bestKey = key
                }
            }
            return bestRow
        }

        private func sortKey(_ row: some TitleGroupedRow) -> TitleGroupSortKey {
            let categoryName = row.categoryId.flatMap { categoryNames[$0] }
            return TitleGroupSortKey(
                member: matcher.memberRank(of: row.id),
                rank: VariantTags(title: row.name, categoryName: categoryName).rank(preferredLanguages: preferredLanguages)
            )
        }
    }

    /// `rows` with each title once, in the position of its first copy. Rows
    /// without a key are never grouped. `grouped == false` returns `rows`.
    static func dedupe<Row: TitleGroupedRow>(_ rows: [Row], ranking: Ranking, grouped: Bool) -> [Row] {
        guard grouped else { return rows }
        var collector = Collector<Row>(seenKeys: [])
        for row in rows {
            collector.add(row)
        }
        return collector.representatives(ranking: ranking)
    }

    /// `items` with each title once, at its first copy's position, as the copy
    /// `best` picks among them, alongside every copy in order. An item `key`
    /// returns nil for is always kept, alone.
    static func collapse<Item>(
        _ items: [Item],
        key: (Item) -> String?,
        best: ([Item]) -> Item
    ) -> [(shown: Item, copies: [Item])] {
        var copiesByKey: [String: [Item]] = [:]
        for item in items {
            if let key = key(item) { copiesByKey[key, default: []].append(item) }
        }
        var emitted = Set<String>()
        return items.compactMap { item in
            guard let key = key(item), let copies = copiesByKey[key] else { return (item, [item]) }
            guard emitted.insert(key).inserted else { return nil }
            return (copies.count > 1 ? best(copies) : item, copies)
        }
    }

    /// The copy of one detail-rail title to show, never the shown title
    /// itself. Grouped, it is the scope's best copy; ungrouped, the first copy
    /// on the shown row's playlist, as before grouping.
    static func railRow<Row: TitleGroupedRow>(
        _ matches: [Row],
        excluding shown: some TitleGroupedRow,
        tab: PlaylistTab,
        ranking: Ranking,
        grouped: Bool
    ) -> Row? {
        let ownKey = shown.titleGroupKey
        let playlistPrefix = shown.playlistPrefix
        let candidates = matches.filter { row in
            guard row.id != shown.id, ownKey == nil || row.titleGroupKey != ownKey else { return false }
            if grouped { return ranking.matcher.contains(row.id, tab) }
            guard let playlistPrefix else { return true }
            return row.id.hasPrefix(playlistPrefix)
        }
        return dedupe(candidates, ranking: ranking, grouped: grouped).first
    }

    /// `rows` with each title once, as its first copy. For lists sorted by
    /// recency, where that copy is the one the viewer last played.
    static func firstPerTitle<Row: TitleGroupedRow>(_ rows: [Row], grouped: Bool) -> [Row] {
        firstPerTitle(rows, grouped: grouped) { $0.titleGroupKey }
    }

    /// `items` with each title once, at its first position; an item `title`
    /// returns nil for is always kept.
    static func firstPerTitle<Item>(_ items: [Item], grouped: Bool, title: (Item) -> String?) -> [Item] {
        guard grouped else { return items }
        var seen = Set<String>()
        return items.filter { item in
            guard let key = title(item) else { return true }
            return seen.insert(key).inserted
        }
    }

    // MARK: - Paging

    /// Where the next page starts in the raw (ungrouped) fetch order, and the
    /// titles earlier pages already showed.
    struct Cursor: Equatable {
        var offset = 0
        var seenKeys = Set<String>()
        var isExhausted = false

        static let start = Cursor()
    }

    struct Page<Row> {
        let rows: [Row]
        let cursor: Cursor

        var hasMore: Bool {
            !cursor.isExhausted
        }
    }

    /// The next `limit` titles after `cursor`. Reads raw rows `limit *
    /// overFetch` at a time through `fetch(offset, limit)` until the page is
    /// full or the source runs out, so grouping never returns a short page
    /// while more titles exist. `siblings`, given the keys on the page, returns
    /// their other copies in scope that the window did not reach, so the
    /// representative is chosen among every copy rather than the ones nearby.
    /// A fetched row that fails `includes` still advances the offset but never
    /// joins the page.
    static func page<Row: TitleGroupedRow>(
        after cursor: Cursor,
        limit: Int,
        overFetch: Int = TitleGrouping.overFetch,
        ranking: Ranking,
        grouped: Bool,
        fetch: (_ offset: Int, _ limit: Int) throws -> [Row],
        includes: (Row) -> Bool = { _ in true },
        siblings: ([String]) -> [Row] = { _ in [] }
    ) rethrows -> Page<Row> {
        guard limit > 0, !cursor.isExhausted else { return Page(rows: [], cursor: cursor) }
        guard grouped else {
            let rows = try fetch(cursor.offset, limit)
            var next = cursor
            next.offset += rows.count
            next.isExhausted = rows.count < limit
            return Page(rows: rows.filter(includes), cursor: next)
        }

        let batchSize = limit * max(overFetch, 1)
        var collector = Collector<Row>(seenKeys: cursor.seenKeys)
        var offset = cursor.offset
        var isExhausted = false

        fill: while true {
            let batch = try fetch(offset, batchSize)
            for (index, row) in batch.enumerated() {
                guard collector.entryCount < limit else {
                    let rest = batch[index...]
                    for later in rest where includes(later) && collector.isOnPage(later) {
                        collector.addCandidate(later)
                    }
                    isExhausted = batch.count < batchSize && !rest.contains { includes($0) && collector.isNew($0) }
                    break fill
                }
                if includes(row) { collector.add(row) }
                offset += 1
            }
            if batch.count < batchSize {
                isExhausted = true
                break
            }
        }

        if !collector.pageKeys.isEmpty {
            for row in siblings(collector.pageKeys) where includes(row) && collector.isOnPage(row) {
                collector.addCandidate(row)
            }
        }

        let next = Cursor(offset: offset, seenKeys: collector.seenKeys, isExhausted: isExhausted)
        return Page(rows: collector.representatives(ranking: ranking), cursor: next)
    }
}

// MARK: - Collector

private nonisolated extension TitleGrouping {
    /// Titles in first-seen order, each with the copies found so far.
    struct Collector<Row: TitleGroupedRow> {
        private var entries: [TitleGroupEntry<Row>] = []
        private var candidates: [String: [Row]] = [:]
        private var candidateIDs = Set<String>()
        private(set) var pageKeys: [String] = []
        private(set) var seenKeys: Set<String>

        init(seenKeys: Set<String>) {
            self.seenKeys = seenKeys
        }

        var entryCount: Int {
            entries.count
        }

        /// A row that would add a title to the page.
        func isNew(_ row: Row) -> Bool {
            guard let key = row.titleGroupKey else { return true }
            return !seenKeys.contains(key)
        }

        /// A copy of a title already on this page.
        func isOnPage(_ row: Row) -> Bool {
            guard let key = row.titleGroupKey else { return false }
            return candidates[key] != nil
        }

        mutating func add(_ row: Row) {
            guard let key = row.titleGroupKey else {
                entries.append(.single(row))
                return
            }
            if candidates[key] != nil {
                addCandidate(row)
            } else if seenKeys.insert(key).inserted {
                entries.append(.group(key))
                pageKeys.append(key)
                candidates[key] = [row]
                candidateIDs.insert(row.id)
            }
        }

        mutating func addCandidate(_ row: Row) {
            guard let key = row.titleGroupKey, candidates[key] != nil, candidateIDs.insert(row.id).inserted else { return }
            candidates[key, default: []].append(row)
        }

        func representatives(ranking: Ranking) -> [Row] {
            entries.compactMap { entry -> Row? in
                switch entry {
                case let .single(row):
                    return row
                case let .group(key):
                    return candidates[key].map { ranking.best(of: $0) }
                }
            }
        }
    }
}

private nonisolated struct TitleGroupSortKey {
    let member: Int
    let rank: VariantTags.Rank

    func precedes(_ other: TitleGroupSortKey) -> Bool {
        if member != other.member { return member < other.member }
        return rank < other.rank
    }
}

/// A page slot: a row that is never grouped, or a title by its key.
private nonisolated enum TitleGroupEntry<Row> {
    case single(Row)
    case group(String)
}
