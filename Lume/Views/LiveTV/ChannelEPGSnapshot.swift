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

        let interval = Perf.begin(.channelEPGLoad)
        defer { Perf.end(interval) }

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

// MARK: - Guide window snapshot

/// A single guide-window programme for a channel — plain values so the whole
/// window can be fetched off the main thread and shaped into grid rows without
/// keeping managed `EPGListing` objects alive on the view context.
nonisolated struct EPGWindowListing: Equatable {
    let id: String
    let title: String
    let detail: String
    let start: Date
    let end: Date
}

/// Loads the full guide window for a set of channels in one indexed, off-main
/// fetch, grouped by channel id and sorted by start. This is the guide grid's
/// counterpart to `ChannelEPGLoader`: it keeps *every* listing in the window
/// (not just now/next) but, crucially, scopes the fetch to the channels on
/// screen and returns `Sendable` snapshots. A view-context `@Query` here would
/// instead materialize the *entire* guide window across every playlist on the
/// main thread — and re-fire on every sync write — which froze the guide open
/// and stuttered scrolling on large playlists.
enum EPGGuideLoader {
    nonisolated static func load(
        container: ModelContainer,
        channelIds: [String],
        windowStart: Date,
        windowEnd: Date
    ) -> [String: [EPGWindowListing]] {
        guard !channelIds.isEmpty else { return [:] }

        let interval = Perf.begin(.guideWindowLoad)
        defer { Perf.end(interval) }

        let context = ModelContext(container)
        // Channel-id scope is index-served; the time bounds trim it to the
        // visible window. Sorted by start so the grid builder can tile in order.
        let descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate {
                channelIds.contains($0.channelId) && $0.end > windowStart && $0.start < windowEnd
            },
            sortBy: [SortDescriptor(\.channelId), SortDescriptor(\.start)]
        )
        guard let listings = try? context.fetch(descriptor) else { return [:] }

        var grouped: [String: [EPGWindowListing]] = [:]
        for listing in listings {
            grouped[listing.channelId, default: []].append(
                EPGWindowListing(
                    id: listing.id,
                    title: listing.title,
                    detail: listing.listingDescription,
                    start: listing.start,
                    end: listing.end
                )
            )
        }
        return grouped
    }
}
