//
//  JellyfinSourceResolver.swift
//  Lume
//
//  The play-time half of a Jellyfin/Emby title's versions: recognise a
//  catalog stream link, ask the server which versions it can play as
//  (`PlaybackInfo`), and build the stream for the one chosen. Catalog rows
//  store the version-less `/Videos/{id}/stream?Static=true`, which the server
//  answers with its first version — so a title plays exactly as before
//  whenever nothing here runs.
//

import Foundation
import OSLog
import SwiftData

nonisolated enum JellyfinSourceResolver {
    enum ResolveError: LocalizedError {
        case noPlayableSources

        var errorDescription: String? {
            switch self {
            case .noPlayableSources:
                String(localized: "The server found no playable sources for this title.")
            }
        }
    }

    /// What a `PlaybackInfo` lookup hands the player: the versions, and the
    /// playback header to open them with — a fresh one when the stored session
    /// had expired and the lookup signed in again.
    struct Listing {
        let options: [MediaSourceOption]
        let httpHeaders: [String: String]?
    }

    /// The server item a catalog stream link plays: `<server>/Videos/<id>/stream`
    /// with a `MediaBrowser` session header. `nil` for anything else — live,
    /// a download, another source type — which then never shows a picker.
    static func itemId(for media: PlayableMedia) -> String? {
        guard media.kind == .vod, !media.url.isFileURL,
              JellyfinPlaybackAuth.token(from: media.httpHeaders) != nil
        else { return nil }
        let parts = media.url.pathComponents
        guard parts.count >= 3, parts[parts.count - 1] == "stream", parts[parts.count - 3] == "Videos" else { return nil }
        let id = parts[parts.count - 2]
        return id.isEmpty ? nil : id
    }

    /// Lists `media`'s versions. Signs in again once when the stored session
    /// was revoked, persisting the new one on the playlist like a sync does.
    @MainActor
    static func listing(for media: PlayableMedia, refresh: Bool, context: ModelContext, client: JellyfinClient = JellyfinClient()) async throws -> Listing {
        guard let itemId = itemId(for: media),
              let playlist = PlayerContentLookup.playlist(for: media.contentRef, in: context),
              MediaServerFlavor(sourceType: playlist.sourceType) != nil,
              let base = URL(string: playlist.serverURL),
              let token = playlist.jellyfinAccessToken, let userId = playlist.jellyfinUserId
        else { throw JellyfinError.invalidURL }
        let server = JellyfinClient.normalizedServerURL(base)
        var session = JellyfinSession(accessToken: token, userId: userId)
        let info: JellyfinPlaybackInfo
        do {
            info = try await fetch(client: client, server: server, session: session, itemId: itemId, refresh: refresh)
        } catch JellyfinError.unauthorized {
            session = try await client.authenticate(server: server, username: playlist.username, password: playlist.password)
            playlist.jellyfinAccessToken = session.accessToken
            playlist.jellyfinUserId = session.userId
            try? context.save()
            info = try await fetch(client: client, server: server, session: session, itemId: itemId, refresh: refresh)
        }
        let options = MediaSourceOption.options(from: info.mediaSources)
        Logger.player.log("Jellyfin PlaybackInfo listed \(options.count, privacy: .public) playable source(s) of \(info.mediaSources.count, privacy: .public)")
        guard !options.isEmpty else { throw ResolveError.noPlayableSources }
        return Listing(options: options, httpHeaders: JellyfinClient.playbackHeaders(token: session.accessToken))
    }

    @concurrent
    private static func fetch(client: JellyfinClient, server: URL, session: JellyfinSession, itemId: String, refresh: Bool) async throws -> JellyfinPlaybackInfo {
        try await client.playbackInfo(server: server, session: session, itemId: itemId, refresh: refresh)
    }

    /// `media`, playing `option` from `startTime`. Same identity, so progress,
    /// Now Playing and Next Up are unchanged; only the stream differs.
    static func media(_ media: PlayableMedia, playing option: MediaSourceOption, headers: [String: String]?, startTime: TimeInterval) -> PlayableMedia {
        var components = URLComponents(url: media.url, resolvingAgainstBaseURL: false)
        var query = (components?.queryItems ?? []).filter { $0.name.caseInsensitiveCompare("MediaSourceId") != .orderedSame }
        query.append(URLQueryItem(name: "MediaSourceId", value: option.mediaSourceId))
        components?.queryItems = query
        let url = components?.url ?? media.url
        return media.replacingStream(url: url, httpHeaders: headers ?? media.httpHeaders, startTime: startTime)
    }
}
