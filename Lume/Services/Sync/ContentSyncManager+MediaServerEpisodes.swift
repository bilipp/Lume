//
//  ContentSyncManager+MediaServerEpisodes.swift
//  Lume
//
//  A Jellyfin/Emby show's episodes fetched when the show is opened, through
//  the per-show `/Shows/{id}/Episodes` route. A stock server's sync already
//  imports every episode; this fills in the shows of an AIOStreams-style
//  server, which lists a library's series but no episodes under it.
//
//  Rows are keyed exactly as the sync keys them, so the two paths meet on the
//  same `Episode` and watch progress never splits across duplicates.
//

import Foundation
import OSLog

extension ContentSyncManager {
    func fetchMediaServerEpisodes(seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        guard let flavor = MediaServerFlavor(sourceType: playlist.sourceType),
              let base = URL(string: playlist.serverURL), base.scheme != nil
        else { return [] }
        let playlistId = playlist.id
        let username = playlist.username
        let password = playlist.password
        let stored = playlist.jellyfinAccessToken.flatMap { token in
            playlist.jellyfinUserId.map { JellyfinSession(accessToken: token, userId: $0) }
        }
        let prefix = "\(playlistId.uuidString)-\(flavor.idInfix)-"
        guard let seriesItemId = Self.mediaServerSeriesItemId(seriesElementId: seriesElementId, prefix: prefix) else { return [] }
        let server = JellyfinClient.normalizedServerURL(base)

        var session: JellyfinSession
        if let stored {
            session = stored
        } else {
            session = try await jellyfinClient.authenticate(server: server, username: username, password: password)
            persistJellyfinSession(session, playlistId: playlistId)
        }
        let items: [JellyfinItem]
        do {
            items = try await allShowEpisodes(server: server, session: session, seriesItemId: seriesItemId)
        } catch JellyfinError.unauthorized {
            session = try await jellyfinClient.authenticate(server: server, username: username, password: password)
            persistJellyfinSession(session, playlistId: playlistId)
            items = try await allShowEpisodes(server: server, session: session, seriesItemId: seriesItemId)
        }
        Logger.database.info("\(flavor.displayName, privacy: .public) show episodes fetched: \(items.count, privacy: .public)")
        return items
            .filter { $0.locationType != "Virtual" }
            .map { Self.parsedMediaServerEpisode($0, idPrefix: prefix, seriesItemId: seriesItemId, server: server, token: session.accessToken) }
    }

    /// The server's id for the show behind a series row, or `nil` for a row
    /// with none — a shell the sync built from an episode's `SeriesName`.
    nonisolated static func mediaServerSeriesItemId(seriesElementId: String, prefix: String) -> String? {
        guard seriesElementId.hasPrefix(prefix) else { return nil }
        let itemId = String(seriesElementId.dropFirst(prefix.count))
        guard !itemId.isEmpty, !itemId.hasPrefix("name-"), !itemId.hasPrefix("episode-") else { return nil }
        return itemId
    }

    private func allShowEpisodes(server: URL, session: JellyfinSession, seriesItemId: String) async throws -> [JellyfinItem] {
        var items: [JellyfinItem] = []
        var total = Int.max
        while items.count < total {
            try Task.checkCancellation()
            let page = try await jellyfinClient.showEpisodes(server: server, session: session, seriesId: seriesItemId, startIndex: items.count)
            total = page.totalRecordCount
            items += page.items
            if page.items.isEmpty { break }
        }
        return items
    }

    nonisolated static func parsedMediaServerEpisode(_ item: JellyfinItem, idPrefix: String, seriesItemId: String, server: URL, token: String) -> ParsedEpisode {
        let image: String? = {
            if let tag = item.primaryImageTag {
                return JellyfinClient.imageURL(server: server, itemId: item.id, tag: tag, token: token)?.absoluteString
            }
            if let tag = item.seriesPrimaryImageTag {
                return JellyfinClient.imageURL(server: server, itemId: item.seriesId ?? seriesItemId, tag: tag, token: token)?.absoluteString
            }
            return nil
        }()
        return ParsedEpisode(
            id: idPrefix + "episode-" + item.id,
            episodeId: item.id,
            title: item.name ?? "",
            containerExtension: item.container?.lowercased() ?? "mkv",
            seasonNum: item.parentIndexNumber ?? 1,
            episodeNum: item.indexNumber ?? 0,
            added: nil,
            directSource: JellyfinClient.streamURL(server: server, itemId: item.id)?.absoluteString,
            durationSecs: item.durationSecs,
            movieImage: image,
            rating: item.communityRating,
            airDate: item.premiereDate.map { String($0.prefix(10)) },
            plot: item.overview
        )
    }
}
