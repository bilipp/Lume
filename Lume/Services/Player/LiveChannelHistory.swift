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

    /// Note that `media` is now the live channel on screen. The previously
    /// current channel slides into the "previous" slot so it can be recalled.
    /// Non-live media and re-selecting the channel already current are ignored,
    /// so a detour through a movie or reopening the same channel never clobbers
    /// the recall pair.
    static func record(_ media: PlayableMedia, defaults: UserDefaults = .standard) {
        guard case let .live(id) = media.contentRef else { return }
        let current = defaults.string(forKey: currentKey)
        guard current != id else { return }
        if let current {
            defaults.set(current, forKey: previousKey)
        }
        defaults.set(id, forKey: currentKey)
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
