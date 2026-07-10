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

/// One directly playable stream candidate from an addon's `/stream/` response,
/// carrying the display fields the in-player source picker shows.
nonisolated struct StremioStreamOption: Identifiable, Equatable {
    /// Position in the addon's response — addons order by their own preference,
    /// so it doubles as a stable row identity for the picker.
    let id: Int
    let url: URL
    /// The addon's short label — typically source and quality
    /// ("Torrentio 4k", "[TB⚡] TorBox Search 2160p").
    let name: String?
    /// The addon's long-form details: release name, codec, size, languages.
    /// Addons predating `description` put this text in `title`.
    let details: String?
    /// See `StremioStreamBehaviorHints.bingeGroup`.
    let bingeGroup: String?
    /// File size in bytes, for the picker's size badge.
    let videoSize: Int64?

    init(id: Int, url: URL, stream: StremioStream) {
        self.id = id
        self.url = url
        name = stream.name
        details = stream.streamDescription ?? stream.title
        bingeGroup = stream.behaviorHints?.bingeGroup
        videoSize = stream.behaviorHints?.videoSize
    }
}

nonisolated enum StremioStreamResolver {
    /// Resolves `media` if it is a deferred Stremio placeholder; otherwise
    /// returns it unchanged. Throws `StremioError` when the addon can't be
    /// reached or returns no directly playable stream. Used where a source
    /// picker makes no sense (live channel surfing); VOD playback goes through
    /// `streamOptions` so the viewer can choose.
    static func resolve(_ media: PlayableMedia, container: ModelContainer) async throws -> PlayableMedia {
        guard let first = try await streamOptions(for: media, container: container).first else {
            throw StremioError.noStreamURL
        }
        Logger.player.log("Stremio resolved a stream URL for \(media.title, privacy: .public)")
        return media.replacingURL(first.url)
    }

    /// All directly playable stream candidates for a deferred Stremio
    /// placeholder, in the addon's own preference order. Torrent, YouTube and
    /// external-browser entries are skipped. Empty when `media` isn't a
    /// Stremio placeholder.
    static func streamOptions(for media: PlayableMedia, container: ModelContainer) async throws -> [StremioStreamOption] {
        guard let (type, id) = StremioLink.decode(media.url) else { return [] }
        guard let playlist = DeferredStreamLink.owningPlaylist(of: media.contentRef, container: container) else {
            throw StremioError.invalidURL
        }
        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
        let streams = try await client.getStreams(type: type, id: id).streams
        return streams.enumerated().compactMap { index, stream in
            stream.playableURL.map { StremioStreamOption(id: index, url: $0, stream: stream) }
        }
    }

    /// The option to play without asking, or `nil` when the viewer should
    /// choose. A lone candidate needs no picker; with the picker disabled the
    /// addon's first (preferred) stream plays, matching pre-picker behaviour;
    /// and a `bingeGroup` match keeps auto-advance and episode hops on the
    /// same source/quality the viewer already picked.
    static func autoPick(
        from options: [StremioStreamOption],
        matching bingeGroup: String?,
        askEnabled: Bool
    ) -> StremioStreamOption? {
        guard options.count > 1 else { return options.first }
        guard askEnabled else { return options.first }
        guard let bingeGroup else { return nil }
        return options.first { $0.bingeGroup == bingeGroup }
    }
}
