//
//  LiveChannelHistory.swift
//  Lume
//
//  Tracks the "recall" pair of live channels — the one playing now and the one
//  watched immediately before it — so the player can jump straight back to the
//  last channel, the way a TV remote's recall/last button does. Persisted in
//  `UserDefaults` so recall survives closing and reopening the player, and kept
//  as pure data resolution (no view state) so it can be unit-tested.
//

import Foundation
import SwiftData

enum LiveChannelHistory {
    private static let currentKey = "player.live.currentChannelId"
    private static let previousKey = "player.live.previousChannelId"
    private static let recentsKey = "player.live.recentChannelIds"

    /// How many channels the in-player "Recent" rail remembers. Capped so the
    /// list stays a quick shortcut rather than a full history.
    private static let recentsLimit = 12

    /// Note that `media` is now the live channel on screen. The previously
    /// current channel slides into the "previous" slot so it can be recalled,
    /// and the channel moves to the front of the most-recently-watched list.
    /// Non-live media is ignored, so a detour through a movie never clobbers
    /// the recall pair or the recents rail.
    static func record(_ media: PlayableMedia, defaults: UserDefaults = .standard) {
        guard case let .live(id) = media.contentRef else { return }

        // Move-to-front in the recents list (deduplicated, capped). Re-selecting
        // the current channel simply keeps it at the front — harmless to rerun.
        var recents = defaults.stringArray(forKey: recentsKey) ?? []
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        defaults.set(Array(recents.prefix(recentsLimit)), forKey: recentsKey)

        // Re-selecting the channel already current leaves the recall pair alone.
        let current = defaults.string(forKey: currentKey)
        guard current != id else { return }
        if let current {
            defaults.set(current, forKey: previousKey)
        }
        defaults.set(id, forKey: currentKey)
    }

    /// The most-recently-watched live channel `id`s, current channel first.
    /// Ordering only — resolution into models is the caller's job so each
    /// channel can be matched to its owning playlist.
    static func recentChannelIds(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: recentsKey) ?? []
    }

    /// The channel to jump back to — the live stream watched immediately before
    /// the current one — resolved into a `PlayableMedia`. `nil` when no prior
    /// channel has been recorded or it can no longer be resolved (e.g. removed
    /// in a sync).
    static func recallMedia(in context: ModelContext, defaults: UserDefaults = .standard) -> PlayableMedia? {
        guard let previousId = defaults.string(forKey: previousKey) else { return nil }
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == previousId })
        descriptor.fetchLimit = 1
        guard let stream = try? context.fetch(descriptor).first,
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context) else { return nil }
        return PlayableMedia.from(stream: stream, playlist: playlist)
    }
}
