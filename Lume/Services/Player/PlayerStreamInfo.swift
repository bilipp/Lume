//
//  PlayerStreamInfo.swift
//  Lume
//
//  Programme-level context for the in-player stream-information caption:
//  the owning playlist's name, plus (for live TV) its now/next EPG.
//  Resolved once per stream into a pure value
//  snapshot so the caption can cache it in `@State` from a single
//  `.task(id:)` instead of re-fetching from a body the playback clock
//  invalidates.
//

import Foundation
import SwiftData

/// A point-in-time snapshot of everything the stream-info caption shows beyond
/// what `PlayableMedia` already carries. Every field is optional; callers
/// collapse the rows they have no value for.
nonisolated struct StreamInfoDetails: Equatable {
    let playlistName: String?
    let epg: ChannelEPG?
}

nonisolated enum PlayerStreamInfo {
    /// The entry point every host uses: the resolve is a handful of SwiftData
    /// fetches that run while the stream is starting, so it stays off the
    /// caller's actor rather than each overlay hopping for itself.
    static func resolveDetached(
        for ref: PlayableMedia.ContentRef,
        container: ModelContainer
    ) async -> StreamInfoDetails {
        await Task.detached(priority: .utility) {
            resolve(for: ref, container: container)
        }.value
    }

    /// The playlist name alone, for hosts that resolve their own EPG and so
    /// need nothing else the full resolve gathers (tvOS) — one fetch, no
    /// channel lookup and no guide pass.
    static func playlistNameDetached(
        for ref: PlayableMedia.ContentRef,
        container: ModelContainer
    ) async -> String? {
        await Task.detached(priority: .utility) {
            PlayerContentLookup.playlist(for: ref, in: ModelContext(container))?.name
        }.value
    }

    /// Resolves the caption's details on a fresh `ModelContext`, so it can be
    /// called from a background `Task` and never touches the view context.
    static func resolve(for ref: PlayableMedia.ContentRef, container: ModelContainer) -> StreamInfoDetails {
        let context = ModelContext(container)
        let playlistName = PlayerContentLookup.playlist(for: ref, in: context)?.name

        // Live TV is the only kind carrying anything beyond the playlist, and
        // only when the channel matched an XMLTV id — which plenty of m3u
        // channels never do, so the programme simply collapses.
        guard case let .live(id) = ref,
              let epgChannelId = PlayerContentLookup.liveStream(id, in: context)?.epgChannelId
        else {
            return StreamInfoDetails(playlistName: playlistName, epg: nil)
        }
        let epg = ChannelEPGLoader.load(container: container, channelIds: [epgChannelId], now: Date())
        return StreamInfoDetails(playlistName: playlistName, epg: epg[epgChannelId])
    }
}
