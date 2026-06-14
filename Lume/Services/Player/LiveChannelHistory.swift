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
    private static let currentKeyBase = "player.live.currentChannelId"
    private static let previousKeyBase = "player.live.previousChannelId"
    private static let recentsKeyBase = "player.live.recentChannelIds"

    /// How many channels the in-player "Recent" rail remembers. Capped so the
    /// list stays a quick shortcut rather than a full history.
    private static let recentsLimit = 12

    /// Per-profile key. The recall pair and recents rail are part of a profile's
    /// live-TV view history, so each profile gets its own namespace. The default
    /// profile keeps the original un-suffixed keys, so an upgrading user's
    /// existing recall/recents carry over (matching how legacy `UserContentState`
    /// records are claimed by the default profile during bootstrap).
    private static func key(_ base: String, _ profileID: UUID?) -> String {
        guard let profileID, profileID != UserProfile.defaultProfileID else { return base }
        return "\(base).\(profileID.uuidString)"
    }

    /// Note that `media` is now the live channel on screen. The previously
    /// current channel slides into the "previous" slot so it can be recalled,
    /// and the channel moves to the front of the most-recently-watched list.
    /// Non-live media is ignored, so a detour through a movie never clobbers
    /// the recall pair or the recents rail.
    static func record(
        _ media: PlayableMedia,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) {
        guard case let .live(id) = media.contentRef else { return }

        let recentsKey = key(recentsKeyBase, profileID)
        let currentKey = key(currentKeyBase, profileID)
        let previousKey = key(previousKeyBase, profileID)

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

    /// The most-recently-watched live channel `id`s for the profile, current
    /// channel first. Ordering only — resolution into models is the caller's job
    /// so each channel can be matched to its owning playlist.
    static func recentChannelIds(
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) -> [String] {
        defaults.stringArray(forKey: key(recentsKeyBase, profileID)) ?? []
    }

    /// The channel to jump back to — the live stream watched immediately before
    /// the current one — resolved into a `PlayableMedia`. `nil` when no prior
    /// channel has been recorded or it can no longer be resolved (e.g. removed
    /// in a sync).
    static func recallMedia(
        in context: ModelContext,
        profileID: UUID? = ActiveProfileStore.current,
        defaults: UserDefaults = .standard
    ) -> PlayableMedia? {
        guard let previousId = defaults.string(forKey: key(previousKeyBase, profileID)) else { return nil }
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == previousId })
        descriptor.fetchLimit = 1
        guard let stream = try? context.fetch(descriptor).first,
              let playlist = LiveChannelNavigator.playlist(for: stream, in: context) else { return nil }
        return PlayableMedia.from(stream: stream, playlist: playlist)
    }

    /// Drop a profile's live-TV view history. Called when a profile is deleted so
    /// its recall pair and recents rail don't linger in `UserDefaults`. The
    /// default profile's un-suffixed keys are never purged this way.
    static func purge(profileID: UUID, defaults: UserDefaults = .standard) {
        guard profileID != UserProfile.defaultProfileID else { return }
        defaults.removeObject(forKey: key(currentKeyBase, profileID))
        defaults.removeObject(forKey: key(previousKeyBase, profileID))
        defaults.removeObject(forKey: key(recentsKeyBase, profileID))
    }
}
