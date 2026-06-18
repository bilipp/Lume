//
//  ChannelEPGSnapshot.swift
//  Lume
//
//  The now/next EPG shown on a channel card, resolved once for a whole list off
//  the main thread. Channel cards used to each register their own `@Query` for
//  EPG listings — a category with hundreds of channels meant hundreds of live
//  SwiftData observers, each running an (unindexed) full scan of the guide table
//  and all re-firing together when an EPG sync wrote new rows. The list owns a
//  single bounded fetch instead and passes each card its precomputed pair.
//

import Foundation
import SwiftData

/// A point-in-time programme entry for a channel card — plain values so it can
/// cross actor boundaries and outlive the fetch without holding a managed object.
nonisolated struct EPGSlot: Equatable {
    let title: String
    let start: Date
    let end: Date
}

/// The now/next programme pair shown on a single channel card.
nonisolated struct ChannelEPG: Equatable {
    let current: EPGSlot?
    let next: EPGSlot?
}

/// Builds the now/next lookup for a set of channels in one indexed fetch, off
/// the main thread, returning only `Sendable` value snapshots.
enum ChannelEPGLoader {
    nonisolated static func load(
        container: ModelContainer,
        channelIds: [String],
        now: Date
    ) -> [String: ChannelEPG] {
        guard !channelIds.isEmpty else { return [:] }

        let context = ModelContext(container)
        // Only currently-airing or upcoming listings matter for now/next; the
        // `end > now` bound (plus the channel-id scope) keeps this to a small,
        // index-served slice of the guide rather than the whole table.
        let descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate { channelIds.contains($0.channelId) && $0.end > now },
            sortBy: [SortDescriptor(\.channelId), SortDescriptor(\.start)]
        )
        guard let listings = try? context.fetch(descriptor) else { return [:] }

        var grouped: [String: [EPGListing]] = [:]
        for listing in listings {
            grouped[listing.channelId, default: []].append(listing)
        }

        var result: [String: ChannelEPG] = [:]
        for (channelId, items) in grouped {
            // `items` are sorted by start and already filtered to `end > now`.
            let current = items.first { $0.start <= now && now < $0.end }
            let next = items.first { $0.start > now }
            result[channelId] = ChannelEPG(
                current: current.map { EPGSlot(title: $0.title, start: $0.start, end: $0.end) },
                next: next.map { EPGSlot(title: $0.title, start: $0.start, end: $0.end) }
            )
        }
        return result
    }
}
