//
//  EPGSyncManager.swift
//  Lume
//
//  The dedicated EPG pipeline, split out of the playlist sync. It rebuilds the
//  whole `EPGListing` store from every enabled `EPGSource`: collect the channel
//  ids any live stream references, download every source's XMLTV file, then
//  stream-parse each file, inserting only programmes whose channel a stream
//  actually uses.
//
//  The old guide stays readable throughout. A programme already stored is
//  updated in place (and left alone when nothing about it changed), a new one
//  is inserted, and only once every file is in are the listings this refresh
//  didn't see deleted. Clearing first emptied the guide for the whole ingest,
//  10 to 15 s on an Apple TV: any list or guide opened in that window, by
//  switching playlists or right after launch, showed the few channels ingested
//  so far.
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
//  A Stalker playlist's source reads the portal's own guide (`get_epg_info`)
//  instead of a file. It runs after every XMLTV source whatever its age, so an
//  attached XMLTV guide keeps the channels it carries and the portal fills the
//  rest.
//

import Foundation
import OSLog
import SwiftData

actor EPGSyncManager {
    /// Fetches a portal's guide for the next `hours` hours.
    typealias PortalGuideFetch = @Sendable (StalkerClient.Configuration, _ hours: Int) async throws -> [StalkerEPGProgramme]

    let modelContainer: ModelContainer
    private let client: M3UClient
    private let fetchPortalGuide: PortalGuideFetch

    init(
        modelContainer: ModelContainer,
        client: M3UClient = M3UClient(),
        fetchPortalGuide: @escaping PortalGuideFetch = { configuration, hours in
            try await StalkerClient(configuration: configuration).getEPGInfo(periodHours: hours)
        }
    ) {
        self.modelContainer = modelContainer
        self.client = client
        self.fetchPortalGuide = fetchPortalGuide
    }

    /// Refreshes the guide from every enabled source. Returns `true` when at
    /// least one source synced successfully.
    ///
    /// - Parameter lockedPlaylistIDs: playlists the free plan locks (see
    ///   `[Playlist].isLocked`). Their linked sources are skipped — the guide
    ///   is fetched from the provider with that playlist's credentials.
    @discardableResult
    func syncAllSources(lockedPlaylistIDs: Set<UUID> = []) async -> Bool {
        let sources = enabledSources(lockedPlaylistIDs: lockedPlaylistIDs)
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

        // Download every source before touching the listings, so a refresh that
        // is cancelled mid-transfer (routine: a content sync cancels a
        // background guide refresh) writes nothing, and which sources failed is
        // known before anything is deleted.
        var downloads: [Download] = []
        for source in sources {
            if let download = await download(source) {
                downloads.append(download)
            }
        }
        defer { removeTempFiles(downloads) }
        guard !downloads.isEmpty, !Task.isCancelled else {
            for download in downloads {
                markStatus(download.source.id, .idle)
            }
            return false
        }

        var anySucceeded = false
        var seenListingIDs: Set<Int> = []
        var unclaimedChannelIDs = knownChannelIDs
        for download in downloads {
            guard !Task.isCancelled else {
                markStatus(download.source.id, .idle)
                continue
            }
            let result = ingest(download, knownChannelIDs: unclaimedChannelIDs)
            unclaimedChannelIDs.subtract(result.claimedChannelIDs)
            seenListingIDs.formUnion(result.listingIDs)
            anySucceeded = anySucceeded || result.didSync
        }

        // A refresh cut short has read only part of the new guide, so nothing
        // is deleted: the refresh owed for it does that.
        guard !Task.isCancelled else { return anySucceeded }
        // A source that failed to download keeps the guide it had: then only
        // the channels this refresh did write lose their outdated listings.
        let allSourcesRead = downloads.count == sources.count
        deleteListings(
            notIn: seenListingIDs,
            on: allSourcesRead ? nil : knownChannelIDs.subtracting(unclaimedChannelIDs)
        )
        return anySucceeded
    }

    // MARK: - Per-source sync

    /// What one source contributed: whether it synced at all, and which channels
    /// it now owns for the rest of this refresh.
    private struct SourceResult {
        let didSync: Bool
        let claimedChannelIDs: Set<String>
        var listingIDs: Set<Int> = []
    }

    /// A source's guide, fetched and ready to ingest.
    private struct Download {
        let source: SourceInfo
        let payload: EPGPayload
    }

    private func removeTempFiles(_ downloads: [Download]) {
        for download in downloads {
            if case let .file(fileURL, isRemote: true) = download.payload {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func download(_ source: SourceInfo) async -> Download? {
        markStatus(source.id, .syncing)
        if let portal = source.portal {
            return await download(source, portal: portal)
        }
        guard !source.url.isEmpty else {
            markStatus(source.id, .error)
            return nil
        }
        do {
            let isRemote = !(URL(string: source.url)?.isFileURL ?? false)
            let fileURL = try await client.downloadEPG(from: source.url)
            return Download(source: source, payload: .file(fileURL, isRemote: isRemote))
        } catch {
            // Credential-free detail (never a URL) so it can be public in
            // user-exported diagnostic logs.
            let nsError = error as NSError
            let detail = (error as? M3UError)?.logDescription ?? "\(nsError.domain) \(nsError.code)"
            let sourceID = source.id
            Logger.database.warning("EPG source \(sourceID, privacy: .public) sync failed: \(detail, privacy: .public)")
            markStatus(source.id, Task.isCancelled ? .idle : .error)
            return nil
        }
    }

    private func download(_ source: SourceInfo, portal: EPGPortalSource) async -> Download? {
        let channelKeys = portalChannelKeys(playlistID: portal.playlistID)
        // No channels stored yet: nothing to ask the portal for, and nothing
        // of this source's to keep.
        guard !channelKeys.isEmpty else { return Download(source: source, payload: .programmes([])) }
        do {
            let entries = try await fetchPortalGuide(portal.configuration, StalkerPortalGuide.periodHours)
            let programmes = StalkerPortalGuide.programmes(from: entries, channelKeys: channelKeys)
            let sourceID = source.id
            Logger.database.info(
                "EPG source \(sourceID, privacy: .public) portal guide: \(entries.count) entries, \(programmes.count) usable"
            )
            return Download(source: source, payload: .programmes(programmes))
        } catch {
            // `logDescription` carries no portal URL, MAC or token.
            let nsError = error as NSError
            let detail = (error as? StalkerError)?.logDescription ?? "\(nsError.domain) \(nsError.code)"
            let sourceID = source.id
            Logger.database.warning("EPG source \(sourceID, privacy: .public) portal guide failed: \(detail, privacy: .public)")
            markStatus(source.id, Task.isCancelled ? .idle : .error)
            return nil
        }
    }

    private func ingest(_ download: Download, knownChannelIDs: Set<String>) -> SourceResult {
        let interval = Perf.begin(.epgSourceSync)
        defer { Perf.end(interval) }

        let sourceID = download.source.id
        guard !knownChannelIDs.isEmpty else {
            // Every channel this source could guide is already covered by an
            // earlier one; ingesting it would only produce overlaps.
            Logger.database.info("EPG source \(sourceID, privacy: .public) skipped, all channels already guided")
            markSynced(sourceID)
            return SourceResult(didSync: true, claimedChannelIDs: [])
        }
        let written = switch download.payload {
        case let .file(fileURL, _):
            writeListings(knownChannelIDs: knownChannelIDs) { onBatch in
                _ = XMLTVParser.parse(fileURL: fileURL, batchSize: 2000, onBatch: onBatch)
            }
        case let .programmes(programmes):
            writeListings(knownChannelIDs: knownChannelIDs) { onBatch in
                for offset in stride(from: 0, to: programmes.count, by: 2000) {
                    onBatch(Array(programmes[offset ..< min(offset + 2000, programmes.count)]))
                }
            }
        }
        Logger.database.info("EPG source \(sourceID) read \(written.count) listings for \(written.channelIDs.count) channels")
        markSynced(sourceID)
        return SourceResult(didSync: true, claimedChannelIDs: written.channelIDs, listingIDs: written.listingIDs)
    }

    // MARK: - Source / channel lookups

    private struct SourceInfo {
        let id: UUID
        let url: String
        /// Set for a Stalker playlist's portal guide.
        var portal: EPGPortalSource?
    }

    /// Every enabled source the plan allows, XMLTV files oldest-first, then
    /// portal guides. A portal source whose playlist is gone is skipped.
    private func enabledSources(lockedPlaylistIDs: Set<UUID>) -> [SourceInfo] {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<EPGSource>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.addedAt)]
        )
        let sources = ((try? context.fetch(descriptor)) ?? [])
            .filter { source in source.playlistID.map { !lockedPlaylistIDs.contains($0) } ?? true }
        var files: [SourceInfo] = []
        var portals: [SourceInfo] = []
        for source in sources {
            guard let playlistID = StalkerPortalGuide.playlistID(fromSourceURL: source.url) else {
                files.append(SourceInfo(id: source.id, url: source.url))
                continue
            }
            guard let playlist = try? context.fetch(
                FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
            ).first, playlist.sourceType == .stalker else { continue }
            portals.append(SourceInfo(
                id: source.id,
                url: source.url,
                portal: EPGPortalSource(
                    playlistID: playlistID,
                    configuration: StalkerClient.Configuration(playlist: playlist, timeout: Self.portalGuideTimeout)
                )
            ))
        }
        return files + portals
    }

    /// The portal builds the whole lineup's guide in one response, which takes
    /// far longer than a catalog page.
    private static let portalGuideTimeout: TimeInterval = 120

    /// A Stalker playlist's channels: `streamId` to EPG channel id.
    private func portalChannelKeys(playlistID: UUID) -> [Int: String] {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let prefix = "\(playlistID.uuidString)-live-"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        descriptor.propertiesToFetch = [\.streamId, \.epgChannelId]
        var keys: [Int: String] = [:]
        for stream in (try? context.fetch(descriptor)) ?? [] {
            guard let epgChannelId = stream.epgChannelId, !epgChannelId.isEmpty else { continue }
            keys[stream.streamId] = epgChannelId
        }
        return keys
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

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// How many `id IN (…)` values one statement carries, well under SQLite's
    /// bound-variable limit.
    private static let lookupChunk = 500

    /// How many listings to work through before saving. Every save on the shared
    /// catalog container merges into the main context and re-runs *every* active
    /// `@Query` (not just `EPGListing` ones) — so a guide that saved once per
    /// 2000-programme parse batch produced dozens of browse-view recompute
    /// storms right after a sync. Coalescing into far larger saves cuts that
    /// churn proportionally; the in-flight listings are tiny, so memory stays
    /// bounded. A stretch of the guide that didn't change saves nothing at all.
    private static let saveThreshold = 10000

    /// What a source contributed: how many listings it held for known
    /// channels, the channels they landed on, and which listings they were.
    private struct WriteResult {
        var count = 0
        var channelIDs: Set<String> = []
        /// Hashes of the listing ids rather than the ids: a large guide runs to
        /// a million listings, and this only has to tell "seen this refresh"
        /// from "not".
        var listingIDs: Set<Int> = []
    }

    /// Stores every programme `produce` hands over, batch by batch, that is on
    /// a known channel: a listing already stored is updated where it differs,
    /// the rest are inserted. An XMLTV source stream-parses its file into it.
    ///
    /// The stored rows are looked up first because inserting over them is not
    /// an option. The id is unique, so SwiftData would resolve each collision
    /// as an upsert, and that path is about 26 times slower than a plain insert
    /// (60,000 listings: 7 s to insert, 189 s to insert again over themselves).
    ///
    /// Parsing streams in 2000-programme batches to keep `ParsedProgramme`
    /// memory flat. Changes accumulate on one context, replaced after every
    /// `saveThreshold` listings so the rows it looked up are released too.
    private func writeListings(
        knownChannelIDs: Set<String>,
        produce: (_ onBatch: @escaping ([ParsedProgramme]) -> Void) -> Void
    ) -> WriteResult {
        let interval = Perf.begin(.epgIngest)
        defer { Perf.end(interval) }

        var result = WriteResult()
        var handled = 0
        let container = modelContainer
        var context = Self.makeContext(container)

        produce { batch in
            autoreleasepool {
                var programmes: [(id: String, programme: ParsedProgramme)] = []
                for programme in batch where knownChannelIDs.contains(programme.channelId) {
                    let id = "\(programme.channelId)-\(Int(programme.start.timeIntervalSince1970))"
                    // A file that lists a programme twice keeps the first.
                    guard result.listingIDs.insert(id.hashValue).inserted else { continue }
                    programmes.append((id, programme))
                }
                let stored = Self.storedListings(ids: programmes.map(\.id), in: context)
                for (id, programme) in programmes {
                    let category = programme.categories.isEmpty ? nil : programme.categories.joined(separator: ", ")
                    if let listing = stored[id] {
                        Self.update(listing, to: programme, category: category)
                    } else {
                        context.insert(EPGListing(
                            id: id,
                            channelId: programme.channelId,
                            title: programme.title,
                            listingDescription: programme.description,
                            start: programme.start,
                            end: programme.end,
                            subtitle: programme.subtitle,
                            category: category
                        ))
                    }
                    result.count += 1
                    result.channelIDs.insert(programme.channelId)
                }
                handled += programmes.count
                if handled >= Self.saveThreshold {
                    if context.hasChanges { try? context.save() }
                    context = Self.makeContext(container)
                    handled = 0
                }
            }
        }

        if context.hasChanges {
            try? context.save()
        }
        return result
    }

    private static func storedListings(ids: [String], in context: ModelContext) -> [String: EPGListing] {
        var stored: [String: EPGListing] = [:]
        for offset in stride(from: 0, to: ids.count, by: lookupChunk) {
            let chunk = Array(ids[offset ..< min(offset + lookupChunk, ids.count)])
            var descriptor = FetchDescriptor<EPGListing>(predicate: #Predicate { chunk.contains($0.id) })
            // Nothing in this context is pending under these ids: each one is
            // handled once per refresh.
            descriptor.includePendingChanges = false
            for listing in (try? context.fetch(descriptor)) ?? [] {
                stored[listing.id] = listing
            }
        }
        return stored
    }

    /// Assigns only what differs, so an unchanged programme isn't written back.
    /// The channel and the start are the listing's id and can't differ.
    private static func update(_ listing: EPGListing, to programme: ParsedProgramme, category: String?) {
        if listing.title != programme.title { listing.title = programme.title }
        if listing.listingDescription != programme.description { listing.listingDescription = programme.description }
        if listing.end != programme.end { listing.end = programme.end }
        if listing.subtitle != programme.subtitle { listing.subtitle = programme.subtitle }
        if listing.category != category { listing.category = category }
    }

    /// Deletes the listings this refresh didn't see: programmes that left the
    /// schedule or moved, and channels no source guides any more. With
    /// `channelIDs`, only on those channels.
    private func deleteListings(notIn seenListingIDs: Set<Int>, on channelIDs: Set<String>?) {
        let context = Self.makeContext(modelContainer)
        var descriptor = FetchDescriptor<EPGListing>()
        descriptor.propertiesToFetch = [\.id, \.channelId]
        var outdated: [String] = []
        do {
            try context.enumerate(descriptor, batchSize: 5000) { listing in
                guard !seenListingIDs.contains(listing.id.hashValue) else { return }
                if let channelIDs, !channelIDs.contains(listing.channelId) { return }
                outdated.append(listing.id)
            }
            guard !outdated.isEmpty else { return }
            for offset in stride(from: 0, to: outdated.count, by: Self.lookupChunk) {
                let chunk = Array(outdated[offset ..< min(offset + Self.lookupChunk, outdated.count)])
                try context.delete(model: EPGListing.self, where: #Predicate { chunk.contains($0.id) })
            }
            try context.save()
        } catch {
            Logger.database.error("Failed to delete outdated EPG listings: \(error.localizedDescription)")
        }
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

/// What a download holds.
private nonisolated enum EPGPayload {
    /// An XMLTV file on disk. `isRemote`: downloaded to a temp file this
    /// refresh owns (a local `file://` source is read in place and never
    /// removed).
    case file(URL, isRemote: Bool)
    /// A portal's guide, already on its channels' EPG ids.
    case programmes([ParsedProgramme])
}

/// The Stalker playlist a portal-guide source reads from.
private nonisolated struct EPGPortalSource {
    let playlistID: UUID
    let configuration: StalkerClient.Configuration
}
