//
//  StalkerStreamResolver.swift
//  Lume
//
//  Turns a deferred Stalker `PlayableMedia` (whose URL is a `lumestalker://`
//  placeholder carrying a `create_link` command) into one with a real, freshly
//  resolved stream URL. Stalker URLs are short-lived, so resolution happens at
//  playback time — right before the engine loads — rather than at sync time.
//

import Foundation
import OSLog
import SwiftData

nonisolated enum StalkerStreamResolver {
    /// Turns a `create_link` command into a fresh stream URL.
    typealias LinkResolver = @Sendable (
        StalkerClient.Configuration, StalkerLink.LinkType, String
    ) async throws -> URL

    static let portalLinkResolver: LinkResolver = { configuration, type, cmd in
        try await StalkerClient(configuration: configuration).resolveStreamURL(type: type, cmd: cmd)
    }

    /// Resolves `media` if it is a deferred Stalker placeholder; otherwise returns
    /// it unchanged. Throws `StalkerError` when the portal can't be reached or
    /// returns no playable URL.
    static func resolve(_ media: PlayableMedia, container: ModelContainer) async throws -> PlayableMedia {
        guard StalkerLink.decode(media.url) != nil else { return media }
        guard let playlist = PlayerContentLookup.playlist(for: media.contentRef, in: ModelContext(container)),
              let url = try await resolve(url: media.url, playlist: playlist)
        else {
            throw StalkerError.invalidURL
        }
        Logger.player.log("Stalker create_link resolved a stream URL for \(media.title, privacy: .public)")
        return media.replacingURL(url)
    }

    /// A fresh stream URL for a deferred Stalker placeholder on `playlist`'s
    /// portal; `nil` when `url` isn't one.
    static func resolve(
        url: URL,
        playlist: Playlist,
        using resolveLink: LinkResolver = portalLinkResolver
    ) async throws -> URL? {
        guard let (type, cmd) = StalkerLink.decode(url) else { return nil }
        return try await resolveOffMain(
            resolveLink, configuration: StalkerClient.Configuration(playlist: playlist), type: type, cmd: cmd
        )
    }

    @concurrent
    private static func resolveOffMain(
        _ resolveLink: LinkResolver,
        configuration: StalkerClient.Configuration,
        type: StalkerLink.LinkType,
        cmd: String
    ) async throws -> URL {
        try await resolveLink(configuration, type, cmd)
    }
}
