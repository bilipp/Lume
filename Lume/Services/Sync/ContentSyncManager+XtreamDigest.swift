//
//  ContentSyncManager+XtreamDigest.swift
//  Lume
//
//  Skip-if-unchanged for the Xtream pipeline's three bulk phases. The m3u and
//  WebDAV pipelines already skip an unchanged source; Xtream re-decoded,
//  re-compared and re-swept its whole catalog on every scheduled refresh —
//  about 18 s on a Mac for a 280k-row provider, behind the blocking sync cover.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// Starts a bulk phase: fetches its payload, or — when the bytes match the
    /// last import and the rows it left are still there — completes the step
    /// and returns `.unchanged`, so the caller skips decode, upsert and sweep.
    ///
    /// The digest is cleared once a new payload arrives and recorded again by
    /// `finishXtreamPhase`, so a run that dies partway leaves nothing the next
    /// sync would trust.
    func beginXtreamPhase<Element: Sendable>(
        _ endpoint: XtreamDigestStore.Endpoint,
        playlistId: UUID,
        reuseUnchanged: Bool,
        progress: SyncProgress?,
        fetch: (_ knownDigest: String?) async throws -> XtreamFetch<[Element]>
    ) async throws -> XtreamFetch<[Element]> {
        await progress?.start(endpoint.step)
        let known = trustedXtreamDigest(endpoint, playlistId: playlistId, reuseUnchanged: reuseUnchanged)
        guard case let .fetched(items, digest) = try await fetch(known) else {
            noteUnchangedXtreamPayload(endpoint, playlistId: playlistId)
            await progress?.complete(endpoint.step)
            return .unchanged
        }
        XtreamDigestStore.remove(playlistId: playlistId, endpoint: endpoint)
        let label = endpoint.label
        // swiftformat:disable:next redundantSelf
        Logger.database.info("Fetched \(items.count) \(label), syncing in batches of \(self.batchSize)")
        await progress?.update(detail: "0 of \(items.count)", fraction: 0)
        return .fetched(items, digest: digest)
    }

    /// Ends a bulk phase that imported: runs its sweep, records the payload's
    /// digest, and completes the step.
    func finishXtreamPhase(
        _ endpoint: XtreamDigestStore.Endpoint,
        payload: (digest: String, count: Int),
        playlistId: UUID,
        progress: SyncProgress?,
        prune: () -> Void
    ) async {
        let (digest, count) = payload
        let pruneInterval = Perf.begin(endpoint.pruneSignpost)
        prune()
        recordXtreamDigest(digest, endpoint, playlistId: playlistId, fetchedCount: count)
        Perf.end(pruneInterval)

        let label = endpoint.label
        Logger.database.info("Completed syncing \(count) \(label)")
        await progress?.complete(endpoint.step)
    }

    /// The digest a phase may skip against, or nil when it must import.
    ///
    /// Only trusted while the store still holds exactly the rows that import
    /// left: anything else (a recreated store, a partly deleted playlist) means
    /// the bytes may match while the catalog does not.
    func trustedXtreamDigest(_ endpoint: XtreamDigestStore.Endpoint, playlistId: UUID, reuseUnchanged: Bool) -> String? {
        guard reuseUnchanged, let entry = XtreamDigestStore.entry(playlistId: playlistId, endpoint: endpoint) else {
            return nil
        }
        guard storedRowCount(endpoint, playlistId: playlistId) == entry.rowCount else {
            XtreamDigestStore.remove(playlistId: playlistId, endpoint: endpoint)
            return nil
        }
        return entry.digest
    }

    /// Notes a phase skipped because its payload matched the last import.
    ///
    /// A false match freezes that part of the catalog silently, so the skip is
    /// logged at `notice`, which `DebugLogExporter` carries.
    func noteUnchangedXtreamPayload(_ endpoint: XtreamDigestStore.Endpoint, playlistId: UUID) {
        let kind = endpoint.rawValue
        Logger.database.notice(
            "Xtream \(kind, privacy: .public) for playlist \(playlistId.uuidString, privacy: .public) unchanged: skipping import and prune"
        )
    }

    /// Records the digest of a payload this device has now imported and swept.
    ///
    /// Not while that kind's sweep is being held back by the coverage gate —
    /// the gate defers deletions to a later sync, which a recorded digest would
    /// stop from running — nor for an empty payload, which is what a provider
    /// outage looks like.
    func recordXtreamDigest(
        _ digest: String,
        _ endpoint: XtreamDigestStore.Endpoint,
        playlistId: UUID,
        fetchedCount: Int
    ) {
        guard fetchedCount > 0, !SweepSkipDefaults.isHoldingBack(playlistId: playlistId, kind: endpoint.sweepKind) else {
            return
        }
        let entry = XtreamDigestStore.Entry(digest: digest, rowCount: storedRowCount(endpoint, playlistId: playlistId))
        XtreamDigestStore.store(entry, playlistId: playlistId, endpoint: endpoint)
    }

    /// The playlist's rows of `endpoint`'s kind — a range count on the unique
    /// `id` index, since every id starts with the playlist UUID.
    private func storedRowCount(_ endpoint: XtreamDigestStore.Endpoint, playlistId: UUID) -> Int {
        let context = ModelContext(modelContainer)
        let prefix = "\(playlistId.uuidString)-\(endpoint.idInfix)-"
        let count: Int? = switch endpoint {
        case .movies:
            try? context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        case .series:
            try? context.fetchCount(FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        case .live:
            try? context.fetchCount(FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        }
        return count ?? -1
    }
}

nonisolated extension XtreamDigestStore.Endpoint {
    /// The kind segment of this endpoint's row ids ("<playlist>-movie-<id>").
    var idInfix: String {
        switch self {
        case .movies: "movie"
        case .series: "series"
        case .live: "live"
        }
    }

    /// The sync step this endpoint's phase reports progress under.
    var step: SyncStep {
        switch self {
        case .movies: .movies
        case .series: .series
        case .live: .liveStreams
        }
    }

    /// How the sync log names the rows.
    var label: String {
        switch self {
        case .movies: "movies"
        case .series: "series"
        case .live: "live streams"
        }
    }

    var pruneSignpost: PerfSignpost {
        switch self {
        case .movies: .pruneMovies
        case .series: .pruneSeries
        case .live: .pruneLiveStreams
        }
    }

    /// The kind `sweepIsAllowed` keys its skip counter on.
    var sweepKind: String {
        switch self {
        case .movies: "movie"
        case .series: "series"
        case .live: "live"
        }
    }
}
