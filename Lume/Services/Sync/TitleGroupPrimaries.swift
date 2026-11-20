//
//  TitleGroupPrimaries.swift
//  Lume
//
//  Keeps `isCategoryGroupPrimary` right for the movie and series rows a write
//  touched: within one category, exactly one row per `titleGroupKey` is the
//  primary, which is the row category grids list.
//

import Foundation
import SwiftData

/// The columns that decide a row's group and its rank inside it.
nonisolated protocol TitleGroupedRow: AnyObject {
    var id: String { get }
    var name: String { get }
    var tmdbId: Int? { get }
    var categoryId: String? { get }
    var titleGroupKey: String? { get set }
    var titleMatchKey: String? { get set }
    var isCategoryGroupPrimary: Bool { get set }
    var indexedAt: Date? { get set }
    /// The id up to the kind marker: what every row of the same playlist
    /// starts with.
    var playlistPrefix: String? { get }
}

nonisolated extension Movie: TitleGroupedRow {
    var playlistPrefix: String? {
        id.components(separatedBy: "-movie-").first
    }
}

nonisolated extension Series: TitleGroupedRow {
    var playlistPrefix: String? {
        id.components(separatedBy: "-series-").first
    }
}

nonisolated enum TitleGroupPrimaries {
    struct CategoryKey: Hashable {
        let categoryId: String
        let titleGroupKey: String
    }

    /// The (category, key) pairs a write touched, per kind.
    struct Touched {
        var movies = Set<CategoryKey>()
        var series = Set<CategoryKey>()

        var isEmpty: Bool {
            movies.isEmpty && series.isEmpty
        }
    }

    /// What a provider write can change about a row's group or its rank,
    /// captured before the write.
    struct RowState: Equatable {
        let categoryId: String?
        let titleGroupKey: String?
        let name: String
        /// The title a tmdbId-carrying row voted on, as a (category, `t:` key)
        /// pair. A `t:` key is its own match key, so the bridge re-checks that
        /// title once the row stops carrying it there; the row's `tmdb:` group
        /// no longer leads to it.
        let carriedTitle: CategoryKey?

        init(_ row: some TitleGroupedRow) {
            categoryId = row.categoryId
            titleGroupKey = row.titleGroupKey
            name = row.name
            if row.tmdbId != nil, let categoryId = row.categoryId, let matchKey = row.titleMatchKey {
                carriedTitle = CategoryKey(categoryId: categoryId, titleGroupKey: matchKey)
            } else {
                carriedTitle = nil
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.categoryId == rhs.categoryId && lhs.titleGroupKey == rhs.titleGroupKey && lhs.name == rhs.name
        }

        var categoryKey: CategoryKey? {
            guard let categoryId, let titleGroupKey else { return nil }
            return CategoryKey(categoryId: categoryId, titleGroupKey: titleGroupKey)
        }

        /// The pairs to re-elect and bridge when the row leaves this state.
        var departedKeys: [CategoryKey] {
            [categoryKey, carriedTitle].compactMap(\.self)
        }
    }

    /// Adds the groups a row left and joined to `keys` when the write changed
    /// its category, key or name.
    static func note(before: RowState, after row: some TitleGroupedRow, into keys: inout Set<CategoryKey>) {
        let after = RowState(row)
        guard before != after else { return }
        keys.formUnion(before.departedKeys)
        if let new = after.categoryKey { keys.insert(new) }
    }

    /// Runs `write` on `row` and notes the groups it moved the row between.
    static func track(_ row: some TitleGroupedRow, into keys: inout Set<CategoryKey>, _ write: () -> Void) {
        let before = RowState(row)
        write()
        note(before: before, after: row, into: &keys)
    }

    /// The groups `rows` sit in: deleting them leaves these to re-elect.
    static func categoryKeys(of rows: some Sequence<some TitleGroupedRow>) -> Set<CategoryKey> {
        Set(rows.lazy.flatMap { RowState($0).departedKeys })
    }

    /// Deletes `row` and notes the group it leaves.
    static func delete(
        _ row: some TitleGroupedRow & PersistentModel,
        from context: ModelContext,
        recordingInto keys: inout Set<CategoryKey>
    ) {
        keys.formUnion(RowState(row).departedKeys)
        context.delete(row)
    }

    /// Sets `titleGroupKey` from the row's tmdbId and name, and `titleMatchKey`
    /// from its name. Deriving a key parses the title, so callers skip it when
    /// neither input changed.
    static func assignKey(to row: some TitleGroupedRow) {
        let matchKey = TitleGroupKey.matchKey(name: row.name)
        let key = TitleGroupKey.key(tmdbId: row.tmdbId, matchKey: matchKey)
        // The indexer stamped an adopter done without searching it.
        if row.tmdbId == nil, row.titleGroupKey?.hasPrefix(TitleGroupKey.tmdbPrefix) == true { row.indexedAt = nil }
        if row.titleGroupKey != key { row.titleGroupKey = key }
        if row.titleMatchKey != matchKey { row.titleMatchKey = matchKey }
    }

    /// Whether a write must re-derive the keys: it changed an input, or the row
    /// lacks one (inserted, or stored before the column existed).
    static func needsKey(_ row: some TitleGroupedRow, previousName: String, previousTmdbId: Int?) -> Bool {
        row.titleGroupKey == nil || row.titleMatchKey == nil
            || row.name != previousName || row.tmdbId != previousTmdbId
    }

    /// Bridges the titles behind every touched group (see `bridge`), then
    /// re-elects the primary of every touched (category, key) group and of
    /// every group the bridge moved a row between, in `context`, without
    /// saving.
    static func recompute(
        categoryKeys touched: Touched,
        in context: ModelContext,
        preferredLanguages: [String] = PlayerLanguageOptions.load().preferredAudioLanguages
    ) {
        var touched = touched
        touched.movies.formUnion(bridge(groupKeys: Set(touched.movies.map(\.titleGroupKey)), using: .movies, in: context))
        touched.series.formUnion(bridge(groupKeys: Set(touched.series.map(\.titleGroupKey)), using: .series, in: context))
        reelect(categoryKeys: touched, in: context, preferredLanguages: preferredLanguages)
    }

    /// Re-elects the primary of every touched (category, key) group in
    /// `context`, without saving. The primary is the best `VariantTags` rank,
    /// ties going to the lowest row id; only rows whose flag changes are written.
    static func reelect(
        categoryKeys touched: Touched,
        in context: ModelContext,
        preferredLanguages: [String] = PlayerLanguageOptions.load().preferredAudioLanguages
    ) {
        if !touched.movies.isEmpty {
            let keys = Set(touched.movies.map { Optional($0.titleGroupKey) })
            let categories = Set(touched.movies.map { Optional($0.categoryId) })
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate {
                keys.contains($0.titleGroupKey) && categories.contains($0.categoryId)
            })
            descriptor.propertiesToFetch = [\.id, \.name, \.categoryId, \.titleGroupKey, \.isCategoryGroupPrimary]
            let rows = (try? context.fetch(descriptor)) ?? []
            elect(in: rows, groups: touched.movies, preferredLanguages: preferredLanguages)
        }
        if !touched.series.isEmpty {
            let keys = Set(touched.series.map { Optional($0.titleGroupKey) })
            let categories = Set(touched.series.map { Optional($0.categoryId) })
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate {
                keys.contains($0.titleGroupKey) && categories.contains($0.categoryId)
            })
            descriptor.propertiesToFetch = [\.id, \.name, \.categoryId, \.titleGroupKey, \.isCategoryGroupPrimary]
            let rows = (try? context.fetch(descriptor)) ?? []
            elect(in: rows, groups: touched.series, preferredLanguages: preferredLanguages)
        }
    }
}

private nonisolated extension TitleGroupPrimaries {
    /// `groups` nil elects every group in `rows`.
    static func elect(in rows: [some TitleGroupedRow], groups: Set<CategoryKey>?, preferredLanguages: [String]) {
        var members: [CategoryKey: [any TitleGroupedRow]] = [:]
        for row in rows {
            // The fetch matches the cross product of keys and categories; only
            // the pairs that were touched are re-elected.
            guard let key = RowState(row).categoryKey, groups?.contains(key) ?? true else { continue }
            members[key, default: []].append(row)
        }
        for group in members.values {
            let primary = group.count == 1 ? group[0] : best(of: group, preferredLanguages: preferredLanguages)
            for row in group {
                let isPrimary = row === primary
                if row.isCategoryGroupPrimary != isPrimary { row.isCategoryGroupPrimary = isPrimary }
            }
        }
    }

    static func best(of group: [any TitleGroupedRow], preferredLanguages: [String]) -> any TitleGroupedRow {
        func rank(_ row: any TitleGroupedRow) -> VariantTags.Rank {
            VariantTags(title: row.name).rank(preferredLanguages: preferredLanguages)
        }
        var bestRow = group[0]
        var bestRank = rank(bestRow)
        for row in group.dropFirst() {
            let rowRank = rank(row)
            if rowRank < bestRank || (rowRank == bestRank && row.id < bestRow.id) {
                bestRow = row
                bestRank = rowRank
            }
        }
        return bestRow
    }
}

// MARK: - Deferred election

nonisolated extension TitleGroupPrimaries {
    /// The groups a bulk import touched, elected once after its last batch
    /// rather than once per batch.
    ///
    /// A persisted flag marks the playlist while touched groups wait for that
    /// pass. An import stopped before `run` leaves its new rows primary
    /// (duplicates show, nothing hides); the next import that finds the flag
    /// re-elects every category of the playlist, because its own dirty check
    /// no longer reports the rows the stopped one wrote.
    struct Deferred {
        /// Past this many touched keys in one category, the pass fetches the
        /// whole category instead of an `IN` over the keys. Keeps every fetch
        /// far below SQLite's 32,766 bound variables, and the set held per
        /// category small during a cold import.
        static let wholeCategoryThreshold = 500
        /// Rows elected per context before it is saved and dropped, so a whole
        /// playlist is never resident at once.
        static let rowsPerSave = 5000

        let playlistId: UUID
        private let electsWholePlaylist: Bool
        private var isMarked: Bool
        private var movies = Scopes()
        private var series = Scopes()

        init(playlistId: UUID) {
            self.playlistId = playlistId
            electsWholePlaylist = UserDefaults.standard.bool(forKey: Self.pendingKey(playlistId: playlistId))
            isMarked = electsWholePlaylist
        }

        static func pendingKey(playlistId: UUID) -> String {
            "sync.titleGroupElectionPending.\(playlistId.uuidString)"
        }

        static func clear(playlistId: UUID) {
            UserDefaults.standard.removeObject(forKey: pendingKey(playlistId: playlistId))
        }

        mutating func add(_ touched: Touched) {
            guard !touched.isEmpty else { return }
            if !isMarked {
                UserDefaults.standard.set(true, forKey: Self.pendingKey(playlistId: playlistId))
                isMarked = true
            }
            movies.add(touched.movies)
            series.add(touched.series)
        }

        /// `TitleGroupPrimaries.track` straight into the deferred set.
        mutating func track(
            _ row: some TitleGroupedRow,
            as kind: WritableKeyPath<Touched, Set<CategoryKey>>,
            _ write: () -> Void
        ) {
            var touched = Touched()
            TitleGroupPrimaries.track(row, into: &touched[keyPath: kind], write)
            add(touched)
        }

        /// Elects every deferred group on contexts of its own, saves, and
        /// clears the flag. A no-op when nothing was touched and no earlier
        /// import left the flag behind.
        mutating func run(
            in container: ModelContainer,
            preferredLanguages: [String] = PlayerLanguageOptions.load().preferredAudioLanguages
        ) throws {
            guard isMarked else { return }
            if electsWholePlaylist {
                let prefix = playlistId.uuidString
                let categories = try ModelContext(container).fetch(FetchDescriptor<Category>(
                    predicate: #Predicate { $0.id.starts(with: prefix) }
                ))
                for category in categories {
                    switch category.typeRaw {
                    case CategoryType.vod.rawValue: movies.whole.insert(category.id)
                    case CategoryType.series.rawValue: series.whole.insert(category.id)
                    default: break
                    }
                }
            }
            if TitleGroupPrimaries.hasBridgeWork(.movies, in: ModelContext(container)) {
                let keys = try movies.groupKeys(in: container, wholeCategory: Self.movieGroupKeys)
                try movies.add(TitleGroupPrimaries.bridge(groupKeys: keys, using: .movies, in: container))
            }
            if TitleGroupPrimaries.hasBridgeWork(.series, in: ModelContext(container)) {
                let keys = try series.groupKeys(in: container, wholeCategory: Self.seriesGroupKeys)
                try series.add(TitleGroupPrimaries.bridge(groupKeys: keys, using: .series, in: container))
            }
            try Self.elect(movies: movies, series: series, in: container, preferredLanguages: preferredLanguages)
            Self.clear(playlistId: playlistId)
            isMarked = false
            movies = Scopes()
            series = Scopes()
        }
    }
}

nonisolated extension TitleGroupPrimaries.Deferred {
    /// Touched keys per category, or the whole category once it passes the
    /// threshold.
    struct Scopes {
        var keys: [String: Set<String>] = [:]
        var whole = Set<String>()

        mutating func add(_ pairs: Set<TitleGroupPrimaries.CategoryKey>) {
            for pair in pairs where !whole.contains(pair.categoryId) {
                keys[pair.categoryId, default: []].insert(pair.titleGroupKey)
                if keys[pair.categoryId, default: []].count > TitleGroupPrimaries.Deferred.wholeCategoryThreshold {
                    keys[pair.categoryId] = nil
                    whole.insert(pair.categoryId)
                }
            }
        }

        /// Every group key in scope; a whole category's are read from the
        /// store.
        func groupKeys(in container: ModelContainer, wholeCategory: (String, ModelContext) throws -> [String]) throws -> Set<String> {
            var result = Set<String>()
            for categoryKeys in keys.values {
                result.formUnion(categoryKeys)
            }
            for categoryId in whole {
                try autoreleasepool {
                    try result.formUnion(wholeCategory(categoryId, ModelContext(container)))
                }
            }
            return result
        }
    }

    static func elect(movies: Scopes, series: Scopes, in container: ModelContainer, preferredLanguages: [String]) throws {
        try elect(movies, in: container, preferredLanguages: preferredLanguages) { categoryId, keys in
            let category: String? = categoryId
            var descriptor: FetchDescriptor<Movie>
            if let keys {
                let optionalKeys = Set(keys.map { Optional($0) })
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.categoryId == category && optionalKeys.contains($0.titleGroupKey)
                })
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.categoryId == category && $0.titleGroupKey != nil
                })
            }
            descriptor.propertiesToFetch = [\.id, \.name, \.categoryId, \.titleGroupKey, \.isCategoryGroupPrimary]
            return descriptor
        }
        try elect(series, in: container, preferredLanguages: preferredLanguages) { categoryId, keys in
            let category: String? = categoryId
            var descriptor: FetchDescriptor<Series>
            if let keys {
                let optionalKeys = Set(keys.map { Optional($0) })
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.categoryId == category && optionalKeys.contains($0.titleGroupKey)
                })
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.categoryId == category && $0.titleGroupKey != nil
                })
            }
            descriptor.propertiesToFetch = [\.id, \.name, \.categoryId, \.titleGroupKey, \.isCategoryGroupPrimary]
            return descriptor
        }
    }
}

private nonisolated extension TitleGroupPrimaries.Deferred {
    static func movieGroupKeys(categoryId: String, in context: ModelContext) throws -> [String] {
        let category: String? = categoryId
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.categoryId == category && $0.titleGroupKey != nil })
        descriptor.propertiesToFetch = [\.titleGroupKey]
        return try context.fetch(descriptor).compactMap(\.titleGroupKey)
    }

    static func seriesGroupKeys(categoryId: String, in context: ModelContext) throws -> [String] {
        let category: String? = categoryId
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.categoryId == category && $0.titleGroupKey != nil })
        descriptor.propertiesToFetch = [\.titleGroupKey]
        return try context.fetch(descriptor).compactMap(\.titleGroupKey)
    }

    /// One fetch per category: a group never spans categories, so each
    /// category's rows are elected on their own.
    static func elect(
        _ scopes: Scopes,
        in container: ModelContainer,
        preferredLanguages: [String],
        descriptor: (String, Set<String>?) -> FetchDescriptor<some PersistentModel & TitleGroupedRow>
    ) throws {
        var work: [(categoryId: String, keys: Set<String>?)] = scopes.whole.map { ($0, nil) }
        work += scopes.keys.filter { !scopes.whole.contains($0.key) }.map { ($0.key, $0.value) }
        guard !work.isEmpty else { return }
        var context = ModelContext(container)
        context.autosaveEnabled = false
        var elected = 0
        for item in work {
            try autoreleasepool {
                let rows = try context.fetch(descriptor(item.categoryId, item.keys))
                TitleGroupPrimaries.elect(in: rows, groups: nil, preferredLanguages: preferredLanguages)
                elected += rows.count
                if elected >= rowsPerSave {
                    if context.hasChanges { try context.save() }
                    context = ModelContext(container)
                    context.autosaveEnabled = false
                    elected = 0
                }
            }
        }
        if context.hasChanges { try context.save() }
    }
}
