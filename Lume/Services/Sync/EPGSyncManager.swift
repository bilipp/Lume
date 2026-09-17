//
//  EPGSyncManager.swift
//  Lume
//
//  The dedicated EPG pipeline, split out of the playlist sync. It rebuilds the
//  whole `EPGListing` store from every enabled `EPGSource`: collect the channel
//  ids any live stream references, bulk-delete the old listings once, then
//  stream-parse each source's XMLTV file and insert only programmes whose
//  channel a stream actually uses.
//
//  A channel is guided by exactly one source. Sources are walked oldest-first
//  and each claims the channels it carries; later sources are then confined to
//  the channels still unclaimed. Without that, two sources covering the same
//  channel both survived — the listing id only collapses programmes whose start
//  matches to the second — and the guide drew their schedules on top of each
//  other.
//
//  Memory stays flat regardless of guide size: files live on disk, and only one
//  batch of `ParsedProgramme` structs is held at a time.
//

import Foundation
import OSLog
import SwiftData

actor EPGSyncManager {
    let modelContainer: ModelContainer
    private let client: M3UClient

    init(modelContainer: ModelContainer, client: M3UClient = M3UClient()) {
        self.modelContainer = modelContainer
        self.client = client
    }

    /// Refreshes the guide from every enabled source. Returns `true` when at
    /// least one source synced successfully.
    @discardableResult
    func syncAllSources() async -> Bool {
        let sources = enabledSources()
        guard !sources.isEmpty else {
            Logger.database.info("No enabled EPG sources, skipping EPG sync")
            return false
        }

        guard let knownChannelIDs = channelIDs() else {
            // Nothing references a guide yet (no live streams synced) — leave any
            // existing listings untouched rather than wiping them for nothing.
            Logger.database.info("No live streams with EPG channel IDs, skipping EPG sync")
            return false
        }

        clearListings()

        var anySucceeded = false
        var unclaimedChannelIDs = knownChannelIDs
        for source in sources {
            let result = await sync(sourceID: source.id, url: source.url, knownChannelIDs: unclaimedChannelIDs)
            unclaimedChannelIDs.subtract(result.claimedChannelIDs)
            anySucceeded = anySucceeded || result.didSync
        }
        return anySucceeded
    }

    // MARK: - Per-source sync

    /// What one source contributed: whether it synced at all, and which channels
    /// it now owns for the rest of this refresh.
    private struct SourceResult {
        let didSync: Bool
        let claimedChannelIDs: Set<String>
    }

    private func sync(sourceID: UUID, url: String, knownChannelIDs: Set<String>) async -> SourceResult {
        let interval = Perf.begin(.epgSourceSync)
        defer { Perf.end(interval) }

        markStatus(sourceID, .syncing)
        guard !url.isEmpty else {
            markStatus(sourceID, .error)
            return SourceResult(didSync: false, claimedChannelIDs: [])
        }
        guard !knownChannelIDs.isEmpty else {
            // Every channel this source could guide is already covered by an
            // earlier one; downloading it would only produce overlaps.
            Logger.database.info("EPG source \(sourceID, privacy: .public) skipped, all channels already guided")
            markSynced(sourceID)
            return SourceResult(didSync: true, claimedChannelIDs: [])
        }
        do {
            let isRemote = !(URL(string: url)?.isFileURL ?? false)
            let fileURL = try await client.downloadEPG(from: url)
            defer { if isRemote { try? FileManager.default.removeItem(at: fileURL) } }

            let inserted = insertListings(from: fileURL, knownChannelIDs: knownChannelIDs)
            Logger.database.info("EPG source \(sourceID) inserted \(inserted.count) listings for \(inserted.channelIDs.count) channels")
            markSynced(sourceID)
            return SourceResult(didSync: true, claimedChannelIDs: inserted.channelIDs)
        } catch {
            // Credential-free detail (never a URL) so it can be public in
            // user-exported diagnostic logs.
            let nsError = error as NSError
            let detail = (error as? M3UError)?.logDescription ?? "\(nsError.domain) \(nsError.code)"
            Logger.database.warning("EPG source \(sourceID, privacy: .public) sync failed: \(detail, privacy: .public)")
            markStatus(sourceID, .error)
            return SourceResult(didSync: false, claimedChannelIDs: [])
        }
    }

    // MARK: - Source / channel lookups

    private struct SourceInfo {
        let id: UUID
        let url: String
    }

    private func enabledSources() -> [SourceInfo] {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<EPGSource>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.addedAt)]
        )
        let sources = (try? context.fetch(descriptor)) ?? []
        return sources.map { SourceInfo(id: $0.id, url: $0.url) }
    }

    /// The set of EPG channel IDs any live stream references, or nil when there
    /// is nothing to guide (so the sync can be skipped without clearing data).
    private func channelIDs() -> Set<String>? {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<LiveStream>()
        descriptor.propertiesToFetch = [\.epgChannelId]
        let streams = (try? context.fetch(descriptor)) ?? []
        let ids = Set(streams.compactMap(\.epgChannelId))
        return ids.isEmpty ? nil : ids
    }

    // MARK: - Listing store

    private func clearListings() {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            try context.delete(model: EPGListing.self)
            try context.save()
        } catch {
            Logger.database.error("Failed to clear existing EPG listings: \(error.localizedDescription)")
        }
    }

    /// How many listings to accumulate before saving. Every save on the shared
    /// catalog container merges into the main context and re-runs *every* active
    /// `@Query` (not just `EPGListing` ones) — so a guide that saved once per
    /// 2000-programme parse batch produced dozens of browse-view recompute
    /// storms right after a sync. Coalescing into far larger saves cuts that
    /// churn proportionally; the in-flight listings are tiny, so memory stays
    /// bounded.
    private static let saveThreshold = 10000

    /// What an XMLTV file contributed: how many listings were inserted, and the
    /// channels they landed on.
    private struct InsertResult {
        var count = 0
        var channelIDs: Set<String> = []
    }

    /// Stream-parses an XMLTV file and inserts every programme on a known
    /// channel.
    ///
    /// Parsing streams in 2000-programme batches to keep `ParsedProgramme`
    /// memory flat, but inserts accumulate on a single context and save only
    /// every `saveThreshold` listings to minimise main-context merges.
    private func insertListings(from fileURL: URL, knownChannelIDs: Set<String>) -> InsertResult {
        let interval = Perf.begin(.epgIngest)
        defer { Perf.end(interval) }

        var result = InsertResult()
        var pendingInserts = 0
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        _ = XMLTVParser.parse(fileURL: fileURL, batchSize: 2000) { batch in
            autoreleasepool {
                for programme in batch where knownChannelIDs.contains(programme.channelId) {
                    let listingId = "\(programme.channelId)-\(Int(programme.start.timeIntervalSince1970))"
                    context.insert(EPGListing(
                        id: listingId,
                        channelId: programme.channelId,
                        title: programme.title,
                        listingDescription: programme.description,
                        start: programme.start,
                        end: programme.end
                    ))
                    result.count += 1
                    result.channelIDs.insert(programme.channelId)
                    pendingInserts += 1
                }
                if pendingInserts >= Self.saveThreshold {
                    try? context.save()
                    pendingInserts = 0
                }
            }
        }

        if pendingInserts > 0 {
            try? context.save()
        }
        return result
    }

    // MARK: - Status bookkeeping

    private func markStatus(_ sourceID: UUID, _ status: SyncStatus) {
        updateSource(sourceID) { $0.syncStatus = status }
    }

    private func markSynced(_ sourceID: UUID) {
        updateSource(sourceID) {
            $0.syncStatus = .idle
            $0.lastSyncDate = Date()
        }
    }

    private func updateSource(_ sourceID: UUID, _ mutate: (EPGSource) -> Void) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let source = try? context.fetch(
            FetchDescriptor<EPGSource>(predicate: #Predicate { $0.id == sourceID })
        ).first else { return }
        mutate(source)
        try? context.save()
    }

    /// Resets any source left `.syncing` by a process that died mid-refresh.
    /// `.syncing` is runtime-only, so a value observed at launch is stale.
    static func recoverInterruptedSyncs(in context: ModelContext) {
        let syncingRaw = SyncStatus.syncing.rawValue
        let descriptor = FetchDescriptor<EPGSource>(
            predicate: #Predicate { $0.syncStatusRaw == syncingRaw }
        )
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }
        for source in stuck {
            source.syncStatus = .idle
        }
        try? context.save()
    }
}
