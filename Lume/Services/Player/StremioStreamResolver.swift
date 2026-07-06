//
//  StremioStreamResolver.swift
//  Lume
//
//  Turns a deferred Stremio `PlayableMedia` (whose URL is a `lumestremio://`
//  placeholder carrying a content type and Stremio id) into one with a real
//  stream URL from the addon's `/stream/{type}/{id}.json` endpoint. Stream
//  URLs can be short-lived or session-bound, so resolution happens at playback
//  time — right before the engine loads — rather than at sync time.
//
//  `DeferredStreamLink` is the source-agnostic front door the player uses: it
//  recognizes both Stalker and Stremio placeholders and dispatches to the
//  matching resolver.
//

import Foundation
import OSLog
import SwiftData

// MARK: - Deferred link dispatch

nonisolated enum DeferredStreamLink {
    /// Whether a `PlayableMedia.url` still needs resolution before it can
    /// reach a playback engine.
    static func isPlaceholder(_ url: URL) -> Bool {
        StalkerLink.isPlaceholder(url) || StremioLink.isPlaceholder(url)
    }

    /// Resolves `media` through whichever source produced its placeholder;
    /// returns it unchanged when it is directly playable.
    static func resolve(_ media: PlayableMedia, container: ModelContainer) async throws -> PlayableMedia {
        if StremioLink.isPlaceholder(media.url) {
            return try await StremioStreamResolver.resolve(media, container: container)
        }
        return try await StalkerStreamResolver.resolve(media, container: container)
    }

    /// Fetches the playlist owning a piece of content. Every catalog id embeds
    /// the playlist UUID as its 36-character prefix, so the playlist is
    /// recoverable from the content reference without threading it through
    /// every call site.
    static func owningPlaylist(of ref: PlayableMedia.ContentRef, container: ModelContainer) -> Playlist? {
        let rawId: String = switch ref {
        case let .movie(id), let .episode(id), let .live(id):
            id
        }
        guard let playlistId = UUID(uuidString: String(rawId.prefix(36))) else { return nil }
        let context = ModelContext(container)
        return try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first
    }
}

// MARK: - Stremio resolution

nonisolated enum StremioStreamResolver {
    /// Resolves `media` if it is a deferred Stremio placeholder; otherwise
    /// returns it unchanged. Throws `StremioError` when the addon can't be
    /// reached or returns no directly playable stream.
    static func resolve(_ media: PlayableMedia, container: ModelContainer) async throws -> PlayableMedia {
        guard let (type, id) = StremioLink.decode(media.url) else { return media }
        guard let playlist = DeferredStreamLink.owningPlaylist(of: media.contentRef, container: container) else {
            throw StremioError.invalidURL
        }
        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
        let streams = try await client.getStreams(type: type, id: id).streams
        guard let url = bestStreamURL(from: streams) else {
            throw StremioError.noStreamURL
        }
        Logger.player.log("Stremio resolved a stream URL for \(media.title, privacy: .public)")
        return media.replacingURL(url)
    }

    /// The first directly playable stream. Addons order streams by their own
    /// preference (typically quality), so first-playable is the intended pick;
    /// torrent, YouTube and external-browser entries are skipped.
    static func bestStreamURL(from streams: [StremioStream]) -> URL? {
        streams.lazy.compactMap(\.playableURL).first
    }
}
