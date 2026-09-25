//
//  ContentSyncManager+Prune.swift
//  Lume
//
//  Prunes stale catalog content with a mark-and-sweep pass. The batched upsert
//  in the Xtream and m3u pipelines only ever inserts or updates the items a
//  fetch returns — it never removes items the provider has since dropped. Left
//  alone, a movie pulled from the provider's library, or a whole category that
//  no longer exists, lingers in the local store forever (storage bloat; the
//  indexer keeps resolving dead titles; browsing shows content that 404s on
//  playback).
//
//  Each sync accumulates the set of ids the provider returned for a content
//  kind ("seen") as it writes the batches, then sweeps the playlist's local rows
//  of that kind, deleting any id not in the set. Episodes cascade from their
//  `Series`; cast cascades from its parent — same cascade `PlaylistDeletion`
//  relies on.
//
//  SAFETY: a sweep against an empty/partial fetch would wipe the playlist's
//  catalog, so the `pruneStale*` sweeps are never called directly by a sync —
//  the guarded entry points below are, and they add the coverage gate a row
//  count alone cannot: `XtreamList` drops the elements that fail to decode and
//  only rethrows when *every* element fails, and a truncated m3u download
//  parses cleanly into a short but valid playlist. Either arrives as a small
//  non-empty payload that would wave the sweep through (see `sweepIsSafe`).
//  Stalker is the exception and calls `pruneStale*` itself.
//  Pruning is confined to the local-only catalog store, so a delete never
//  propagates to CloudKit; and user state (favorites, progress, watchlist)
//  lives in `UserContentState` in the cloud mirror keyed by `contentId`, so it
//  survives a prune and is re-applied if the content ever returns.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - Xtream sweep entry points

    // These wrap the per-kind sweep with the non-empty-fetch guard and the
    // coverage check, so the batch-sync functions stay a single call. A working
    // Xtream provider never returns zero of a kind, so an empty fetch is a
    // transient failure — skipping the sweep then keeps the library.
    //
    // `seenIds` is accumulated by the caller's batch loop rather than derived
    // from the DTO array here: holding the decoded payload alive across the
    // sweep is what put the content phases in jetsam range on an Apple TV.
    // `fetchedCount` carries the payload's row count, which the array no longer
    // can once it has been released.

    func pruneMovies(playlistId: UUID, seenIds: Set<String>, fetchedCount: Int) {
        guard fetchedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "movie", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)
    }

    func pruneSeries(playlistId: UUID, seenIds: Set<String>, fetchedCount: Int) {
        guard fetchedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "series", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        pruneStaleSeries(playlistId: playlistId, seenIds: seenIds)
    }

    func pruneLiveStreams(playlistId: UUID, seenIds: Set<String>, fetchedCount: Int) {
        guard fetchedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "live", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        pruneStaleLiveStreams(playlistId: playlistId, seenIds: seenIds)
    }

    // MARK: - Per-kind sweeps

    /// Deletes movies for `playlistId` whose id is absent from `seenIds`.
    func pruneStaleMovies(playlistId: UUID, seenIds: Set<String>) {
        sweepMovies(playlistId: playlistId) { seenIds.contains($0) }
    }

    /// Deletes series for `playlistId` whose id is absent from `seenIds`. Each
    /// removed series' episodes and cast cascade from the series — which is why
    /// the sweep deletes row by row instead of `delete(model:where:)`, whose
    /// bulk delete would leave those children (and the watch progress on them)
    /// orphaned.
    func pruneStaleSeries(playlistId: UUID, seenIds: Set<String>) {
        sweepSeries(playlistId: playlistId) { seenIds.contains($0) }
    }

    /// Deletes live streams for `playlistId` whose id is absent from `seenIds`.
    func pruneStaleLiveStreams(playlistId: UUID, seenIds: Set<String>) {
        sweepLiveStreams(playlistId: playlistId) { seenIds.contains($0) }
    }

    /// Deletes episodes for `playlistId` whose id is absent from `seenIds`,
    /// leaving their series in place. Used by the m3u pipeline, where episodes
    /// are imported alongside the rest of the catalog; the Xtream pipeline pulls
    /// episodes lazily per-series and so isn't swept here.
    func pruneStaleEpisodes(playlistId: UUID, seenIds: Set<String>) {
        sweepEpisodes(playlistId: playlistId) { seenIds.contains($0) }
    }

    // MARK: - m3u sweep entry points

    // Same sweeps, membership tested against `M3UIdentity.hash64` of the id
    // instead of the id itself. A provider m3u file carries ~1.5M episode ids of
    // ~78 characters each — past Swift's inline small-string form, so every one
    // is a separate heap allocation — and the sets stay live across the whole
    // import and every sweep: ~337 MB resident against ~19-33 MB for the hashes.
    //
    // A 64-bit hash collides with probability ~6e-8 at 1.5M keys, and the
    // direction is benign: a collision makes a stale row test as seen, so the
    // sweep KEEPS it. It can never delete a row the file still carries.

    func pruneStaleM3UMovies(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepMovies(playlistId: playlistId) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    func pruneStaleM3USeries(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepSeries(playlistId: playlistId) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    func pruneStaleM3ULiveStreams(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepLiveStreams(playlistId: playlistId) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    func pruneStaleM3UEpisodes(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepEpisodes(playlistId: playlistId) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    // MARK: - m3u guarded sweep entry points

    // The m3u file is one uninterrupted `Transfer-Encoding: chunked` response
    // with no `Content-Length`, so a connection cut mid-download leaves a
    // *valid* short playlist: the parse succeeds, the import commits, and the
    // rows the truncated tail never mentioned look dropped. Sweeping on that
    // deletes them, and the iCloud reconcile that follows
    // `.lumeContentSyncDidComplete` turns each delete into a push that destroys
    // the matching `UserContentState` on every device. So the m3u sweeps take
    // the same gate as the Xtream ones: a payload must cover at least a tenth
    // of the rows already stored, tolerated `maximumConsecutiveSweepSkips`
    // times before a shrink is believed.
    //
    // Deliberate behaviour change: a provider that genuinely drops a whole
    // section now keeps those dead rows for up to two extra syncs.
    //
    // `importedCount` is the import's TOTAL row count, not the kind's — a
    // live-only playlist imports zero movies and must still prune the movies it
    // used to carry, while a zero total means the download or parse produced
    // nothing at all.
    //
    // The coverage floor counts the seen set against the playlist-scoped stored
    // rows, so it reads the same whether the set holds ids or their hashes.

    func pruneLiveStreams(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "live", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3ULiveStreams(playlistId: playlistId, seenHashes: seenHashes)
    }

    func pruneMovies(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "movie", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3UMovies(playlistId: playlistId, seenHashes: seenHashes)
    }

    func pruneEpisodes(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Episode>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "episode", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3UEpisodes(playlistId: playlistId, seenHashes: seenHashes)
    }

    func pruneSeries(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "series", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3USeries(playlistId: playlistId, seenHashes: seenHashes)
    }

    /// Guarded `pruneStaleCategories`. Scoped per type, and so is the skip
    /// count: the three types are accumulated from one file but a truncation
    /// starves them independently.
    func pruneCategories(playlistId: UUID, type: CategoryType, seenApiIds: Set<String>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let scope = FetchDescriptor<Category>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(
            playlistId: playlistId,
            kind: "category.\(type.rawValue)",
            seenCount: seenApiIds.count,
            storedMatching: scope
        ) else {
            return
        }
        pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: seenApiIds)
    }

    // MARK: - Shared sweep bodies

    private func sweepMovies(playlistId: UUID, isSeen: (String) -> Bool) {
        // Scope to the playlist via its UUID, which anchors every id this
        // playlist produced (see PlaylistDeletion). `starts(with:)` compiles to
        // a range seek on the unique `id` index; the substring match used before
        // was a LIKE-%…% scan that touched every row on each sync's sweep.
        let prefix = playlistId.uuidString
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (movie: Movie) in movie.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale movie(s) for playlist \(prefix)")
    }

    private func sweepSeries(playlistId: UUID, isSeen: (String) -> Bool) {
        let prefix = playlistId.uuidString
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (show: Series) in show.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale series for playlist \(prefix)")
    }

    private func sweepLiveStreams(playlistId: UUID, isSeen: (String) -> Bool) {
        let prefix = playlistId.uuidString
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (stream: LiveStream) in stream.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale live stream(s) for playlist \(prefix)")
    }

    private func sweepEpisodes(playlistId: UUID, isSeen: (String) -> Bool) {
        // Episode.id is "\(seriesId)-episode-…" and seriesId starts with the
        // playlist UUID, so the same prefix scope applies.
        let prefix = playlistId.uuidString
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (episode: Episode) in episode.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale episode(s) for playlist \(prefix)")
    }

    /// Deletes categories of `type` for `playlistId` whose `apiId` is absent
    /// from `seenApiIds`. Scoped per type — VOD / series / live categories sync
    /// from separate provider calls, so a `seenApiIds` set for one type must not
    /// reach another type's rows.
    func pruneStaleCategories(playlistId: UUID, type: CategoryType, seenApiIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Match buildExistingCategoryLookup: fetch by indexed typeRaw, then
        // filter to this playlist by the id prefix in memory.
        let prefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let typeRaw = type.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.typeRaw == typeRaw }
        )
        var removed = 0
        for category in (try? context.fetch(descriptor)) ?? []
            where category.id.hasPrefix(prefix) && !seenApiIds.contains(category.apiId)
        {
            context.delete(category)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale \(typeRaw) category/ies for playlist \(prefix)")
    }

    // MARK: - Paged sweep

    /// Deletes the rows `page` returns that `seenIds` doesn't cover, one page at
    /// a time, and answers how many went.
    ///
    /// Paging is what keeps the sweep off the heap: fetching a playlist's whole
    /// catalog materialised every row as a managed object — 178k VOD rows cost
    /// ~1.2 GB peak even when nothing was deleted. Each page runs on its own
    /// `ModelContext` inside an `autoreleasepool`, so a page's objects are gone
    /// before the next one is read.
    ///
    /// Pages are keyed on the last id seen, never on `fetchOffset`: an offset
    /// makes the store walk the rows it is skipping, which turned the same sweep
    /// into ~99 s of index scanning (against 9 s for the single unbounded
    /// fetch). Seeking on `id` instead is also what makes deleting while paging
    /// sound — every row a page removes sorts at or before the cursor, so it
    /// cannot displace a row the next page has yet to see. `page` must therefore
    /// ask for `id > cursor` ordered by `id`, and `after` must be a string that
    /// sorts before every id in scope (the playlist prefix does: a prefix sorts
    /// before anything extending it). The cursor strictly increases each pass
    /// and a short page means the rows ran out, so the loop terminates.
    ///
    /// Membership is a closure rather than a `Set<String>` so a caller can hold
    /// its seen ids in a cheaper form: the m3u pipeline keeps 64-bit hashes
    /// instead of the ids themselves (see `pruneStaleM3U*`).
    private func sweepPaged<T: PersistentModel>(
        after: String,
        isSeen: (String) -> Bool,
        idOf: (T) -> String,
        pageSize: Int = 2000,
        page: (_ cursor: String, _ limit: Int) -> FetchDescriptor<T>
    ) -> Int {
        var cursor = after
        var totalRemoved = 0

        while true {
            var fetched = 0
            var removed = 0

            autoreleasepool {
                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false

                let rows = (try? context.fetch(page(cursor, pageSize))) ?? []
                fetched = rows.count
                if let last = rows.last { cursor = idOf(last) }

                for row in rows where !isSeen(idOf(row)) {
                    context.delete(row)
                    removed += 1
                }
                if removed > 0 { try? context.save() }
            }

            totalRemoved += removed
            if fetched < pageSize { break }
        }

        return totalRemoved
    }

    /// Whether a provider payload accounts for enough of the rows already stored
    /// to be trusted to drive a sweep.
    ///
    /// `XtreamList` drops elements that fail to decode and rethrows only when
    /// *every* element fails, so a payload whose rows are mostly malformed
    /// arrives as a small non-empty array that the callers' `isEmpty` guards let
    /// through — and sweeping against it would delete nearly the whole catalog
    /// along with the enrichment and ordering on those rows.
    ///
    /// This test alone is not enough to decide, because it compares the payload
    /// against the rows already stored and those rows only ever fall when a
    /// sweep runs: a library that legitimately shrinks past the floor would fail
    /// the check on every future sync too, and keep its dead rows forever. See
    /// `sweepIsAllowed` for the bounded tolerance that resolves it. Counting is
    /// an aggregate query, so it costs no materialised rows.
    private func sweepIsSafe(
        seenCount: Int,
        storedMatching descriptor: FetchDescriptor<some PersistentModel>,
        minimumCoverage: Double = 0.1
    ) -> Bool {
        let context = ModelContext(modelContainer)
        guard let stored = try? context.fetchCount(descriptor) else { return false }
        return Double(seenCount) >= Double(stored) * minimumCoverage
    }

    /// Consecutive low-coverage payloads tolerated before a sweep runs anyway.
    ///
    /// Two syncs of protection: a malformed payload is transient and will not
    /// repeat this many times, while a real shrink repeats every sync and so
    /// converges on the third.
    private static let maximumConsecutiveSweepSkips = 2

    /// Whether to sweep, given the coverage test and how often it has already
    /// refused for this playlist and kind.
    ///
    /// `sweepIsSafe` protects the catalog from a payload whose rows mostly
    /// failed to decode. On its own it is a trap: coverage is measured against
    /// the stored rows, which a skipped sweep never reduces, so a subscription
    /// that legitimately shrinks below the floor — a downgraded plan, a provider
    /// that replaced its lineup — would be refused on every subsequent sync and
    /// strand the dead rows permanently. Counting the consecutive refusals and
    /// letting the sweep through after a bounded number keeps the protection
    /// against a bad payload while still converging on a real shrink.
    ///
    /// The count is kept in `UserDefaults` rather than in memory because a sync
    /// commonly follows a fresh launch, and an in-memory counter would reset
    /// before it ever reached the limit.
    private func sweepIsAllowed(
        playlistId: UUID,
        kind: String,
        seenCount: Int,
        storedMatching descriptor: FetchDescriptor<some PersistentModel>
    ) -> Bool {
        let prefix = playlistId.uuidString
        if sweepIsSafe(seenCount: seenCount, storedMatching: descriptor) {
            clearSweepSkips(playlistId: playlistId, kind: kind)
            return true
        }

        let skips = recordSweepSkip(playlistId: playlistId, kind: kind)
        guard skips > Self.maximumConsecutiveSweepSkips else {
            Logger.database.warning(
                "Skipped \(kind, privacy: .public) prune for playlist \(prefix, privacy: .public): payload covers too few stored rows (\(skips, privacy: .public) in a row)"
            )
            return false
        }

        Logger.database.warning(
            "Sweeping \(kind, privacy: .public) for playlist \(prefix, privacy: .public) after \(skips, privacy: .public) low-coverage payloads: treating the shrink as real"
        )
        clearSweepSkips(playlistId: playlistId, kind: kind)
        return true
    }

    private func recordSweepSkip(playlistId: UUID, kind: String) -> Int {
        let key = SweepSkipDefaults.key(playlistId: playlistId, kind: kind)
        let next = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(next, forKey: key)
        return next
    }

    private func clearSweepSkips(playlistId: UUID, kind: String) {
        UserDefaults.standard.removeObject(forKey: SweepSkipDefaults.key(playlistId: playlistId, kind: kind))
    }
}

/// Where `sweepIsAllowed` keeps its consecutive-skip counters.
///
/// Device-local by design: the counter describes what this device's downloads
/// looked like, and mirroring it would let one device's bad payload suppress
/// another's sweep. That makes them invisible to the playlist's own deletion
/// cascade, so the layout is spelled out here for `PlaylistDeletion` to clear —
/// otherwise every deleted playlist leaks a key per content kind.
nonisolated enum SweepSkipDefaults {
    static func key(playlistId: UUID, kind: String) -> String {
        "\(keyPrefix(playlistId: playlistId))\(kind)"
    }

    /// Whether any sweep for this playlist is currently being held back. The m3u
    /// digest skip reads it: a deferred sweep is unfinished work, and recording
    /// the file as fully imported would strand those rows until the provider
    /// changed the file.
    static func hasAny(playlistId: UUID) -> Bool {
        let prefix = keyPrefix(playlistId: playlistId)
        return UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix(prefix) }
    }

    static func removeAll(playlistId: UUID) {
        let prefix = keyPrefix(playlistId: playlistId)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func keyPrefix(playlistId: UUID) -> String {
        "sync.sweepSkips.\(playlistId.uuidString)."
    }
}
