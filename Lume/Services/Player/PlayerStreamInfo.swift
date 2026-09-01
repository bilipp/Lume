//
//  PlayerStreamInfo.swift
//  Lume
//
//  Programme-level context for the in-player stream-information caption:
//  the owning playlist's name, plus (for live TV) its category and its
//  now/next EPG. Resolved once per stream into a pure value
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
    let categoryName: String?
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

    /// The playlist name alone, for hosts whose caption shows nothing else the
    /// full resolve gathers (tvOS) — one fetch instead of four.
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

        switch ref {
        case let .live(id):
            guard let stream = PlayerContentLookup.liveStream(id, in: context) else {
                return StreamInfoDetails(playlistName: playlistName, categoryName: nil, epg: nil)
            }
            let epg = ChannelEPGLoader.load(
                container: container,
                channelIds: [stream.epgChannelId].compactMap(\.self),
                now: Date()
            )
            return StreamInfoDetails(
                playlistName: playlistName,
                categoryName: categoryName(stream.categoryId, in: context),
                epg: stream.epgChannelId.flatMap { epg[$0] }
            )
        case let .movie(id):
            return StreamInfoDetails(
                playlistName: playlistName,
                categoryName: categoryName(PlayerContentLookup.movie(id, in: context)?.categoryId, in: context),
                epg: nil
            )
        case .episode:
            // Episodes carry no category of their own; the series' one is a
            // different level of the hierarchy, so the row collapses instead.
            return StreamInfoDetails(playlistName: playlistName, categoryName: nil, epg: nil)
        }
    }

    // MARK: - Resolution

    private static func categoryName(_ id: String?, in context: ModelContext) -> String? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.name
    }
}
