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
    /// Resolves `media` if it is a deferred Stalker placeholder; otherwise returns
    /// it unchanged. Throws `StalkerError` when the portal can't be reached or
    /// returns no playable URL.
    static func resolve(_ media: PlayableMedia, container: ModelContainer) async throws -> PlayableMedia {
        guard let (type, cmd) = StalkerLink.decode(media.url) else { return media }
        guard let playlist = DeferredStreamLink.owningPlaylist(of: media.contentRef, container: container) else {
            throw StalkerError.invalidURL
        }
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
        let url = try await client.resolveStreamURL(type: type, cmd: cmd)
        Logger.player.log("Stalker create_link resolved a stream URL for \(media.title, privacy: .public)")
        return media.replacingURL(url)
    }
}
