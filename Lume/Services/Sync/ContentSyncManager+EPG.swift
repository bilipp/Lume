//
//  ContentSyncManager+EPG.swift
//  Lume
//
//  Shared XMLTV import used by both the Xtream and m3u pipelines — only where
//  the guide file comes from differs.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// The set of EPG channel IDs any live stream references, or nil when there
    /// is nothing to guide (so EPG sync can be skipped).
    func epgChannelIDs() throws -> Set<String>? {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<LiveStream>()
        descriptor.propertiesToFetch = [\.epgChannelId]
        let streams = try context.fetch(descriptor)
        let knownChannelIDs = Set(streams.compactMap(\.epgChannelId))

        guard !knownChannelIDs.isEmpty else {
            Logger.database.info("No live streams with EPG channel IDs, skipping EPG sync")
            return nil
        }
        Logger.database.info("Found \(knownChannelIDs.count) unique EPG channel IDs")
        return knownChannelIDs
    }

    /// Replaces all stored EPG listings with the contents of an XMLTV file:
    /// bulk-delete, then stream-parse and insert in batches.
    func importEPGFile(_ fileURL: URL, knownChannelIDs: Set<String>) {
        do {
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            try context.delete(model: EPGListing.self)
            try context.save()
        } catch {
            Logger.database.error("Failed to clear existing EPG listings: \(error.localizedDescription)")
        }

        Logger.database.info("Parsing XMLTV and inserting EPG listings")
        var insertedCount = 0
        let container = modelContainer

        let totalCount = XMLTVParser.parse(fileURL: fileURL, batchSize: 2000) { batch in
            insertedCount += Self.insertEPGBatch(batch, knownChannelIDs: knownChannelIDs, into: container)
        }

        Logger.database.info("Completed EPG sync (\(totalCount) parsed, \(insertedCount) inserted for \(knownChannelIDs.count) channels)")
    }

    /// Filters a parsed batch to known channels and inserts into a fresh context.
    /// Returns the number of listings inserted.
    private static func insertEPGBatch(
        _ batch: [ParsedProgramme],
        knownChannelIDs: Set<String>,
        into container: ModelContainer
    ) -> Int {
        let relevant = batch.filter { knownChannelIDs.contains($0.channelId) }
        guard !relevant.isEmpty else { return 0 }

        autoreleasepool {
            let context = ModelContext(container)
            context.autosaveEnabled = false

            for programme in relevant {
                let listingId = "\(programme.channelId)-\(Int(programme.start.timeIntervalSince1970))"
                let listing = EPGListing(
                    id: listingId,
                    channelId: programme.channelId,
                    title: programme.title,
                    listingDescription: programme.description,
                    start: programme.start,
                    end: programme.end
                )
                context.insert(listing)
            }

            try? context.save()
        }
        return relevant.count
    }
}
