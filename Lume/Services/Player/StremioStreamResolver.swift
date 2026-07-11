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
    /// HTTP headers the addon requires on the media request
    /// (`behaviorHints.proxyHeaders.request`) — MediaFusion's media proxy and
    /// header-guarded live-TV addons refuse plain requests.
    let headers: [String: String]?

    init(id: Int, url: URL, stream: StremioStream) {
        self.id = id
        self.url = url
        name = stream.name
        details = stream.streamDescription ?? stream.title
        bingeGroup = stream.behaviorHints?.bingeGroup
        videoSize = stream.behaviorHints?.videoSize
        headers = stream.requestHeaders
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
        return media.replacingURL(first.url, httpHeaders: first.headers)
    }

    /// All directly playable stream candidates for a deferred Stremio
    /// placeholder, in the addon's own preference order. Torrent, YouTube and
    /// external-browser entries are skipped. Empty when `media` isn't a
    /// Stremio placeholder.
    ///
    /// The owning playlist's addon is asked first. When it yields nothing
    /// playable — catalog/meta-only addons like Anime Kitsu, TMDB or Trakt
    /// lists serve no streams at all — the user's *other* Stremio playlists
    /// whose manifests declare stream support for this type and id prefix are
    /// asked, mirroring how the official app aggregates every installed addon
    /// on each play.
    static func streamOptions(for media: PlayableMedia, container: ModelContainer) async throws -> [StremioStreamOption] {
        guard let (type, id) = StremioLink.decode(media.url) else { return [] }
        guard let playlist = DeferredStreamLink.owningPlaylist(of: media.contentRef, container: container) else {
            throw StremioError.invalidURL
        }
        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
        let streams = try await client.getStreams(type: type, id: id).streams
        let own = options(from: streams)
        if !own.isEmpty { return own }
        return await fallbackStreamOptions(type: type, id: id, excluding: playlist.id, container: container)
    }

    /// Maps an addon's raw stream list onto the directly playable candidates,
    /// keeping the addon's order.
    private static func options(from streams: [StremioStream]) -> [StremioStreamOption] {
        streams.enumerated().compactMap { index, stream in
            stream.playableURL.map { StremioStreamOption(id: index, url: $0, stream: stream) }
        }
    }

    /// Stream candidates from every other Stremio playlist whose addon
    /// declares stream support for `type` + `id`'s prefix. Addons are queried
    /// in parallel and merged in playlist order; a failing addon contributes
    /// nothing. Empty when the user has no other capable Stremio playlist.
    private static func fallbackStreamOptions(
        type: String,
        id: String,
        excluding playlistId: UUID,
        container: ModelContainer
    ) async -> [StremioStreamOption] {
        let stremioRaw = PlaylistSourceType.stremio.rawValue
        let context = ModelContext(container)
        let manifestURLs = ((try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.sourceTypeRaw == stremioRaw && $0.id != playlistId })
        )) ?? []).map(\.serverURL)
        guard !manifestURLs.isEmpty else { return [] }

        let prefix = idPrefix(of: id)
        let streamLists = await withTaskGroup(of: (Int, [StremioStream]).self) { group in
            for (index, manifestURL) in manifestURLs.enumerated() {
                group.addTask {
                    let client = StremioClient(
                        configuration: StremioClient.Configuration(manifestURL: manifestURL, timeout: 15)
                    )
                    guard let manifest = try? await client.getManifest(),
                          manifest.supportsStreams(forType: type, idPrefix: prefix),
                          let streams = try? await client.getStreams(type: type, id: id).streams
                    else { return (index, []) }
                    return (index, streams)
                }
            }
            var collected: [(Int, [StremioStream])] = []
            for await entry in group {
                collected.append(entry)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let merged = options(from: Array(streamLists.joined()))
        if !merged.isEmpty {
            Logger.player.log("Stremio: owning addon served no streams; \(merged.count) candidates came from other Stremio playlists")
        }
        return merged
    }

    /// The manifest-style prefix of a Stremio id, for matching an addon's
    /// declared `idPrefixes`: IMDb ids declare the literal `"tt"`, namespaced
    /// ids (`kitsu:1234:1`) their namespace.
    static func idPrefix(of id: String) -> String {
        if id.hasPrefix("tt") { return "tt" }
        return String(id.prefix { $0 != ":" })
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

// MARK: - Subtitle resolution

/// Fetches external subtitle tracks for a deferred Stremio placeholder from
/// the addon protocol's `subtitles` resource, merging every source the
/// official app would ask: the playlist's own addon (subtitle-capable addons
/// like Anime Kitsu serve their catalog's ids), the user's other Stremio
/// playlists that declare subtitle support, and the OpenSubtitles v3
/// community addon for IMDb-keyed titles — the latter pre-installed in the
/// Stremio app, the same standing Cinemeta has on the catalog/meta side.
nonisolated enum StremioSubtitleResolver {
    /// How many tracks of the same language to keep. OpenSubtitles alone
    /// returns dozens of variants per language; the engines' track menus are
    /// flat lists, so the tail is cut rather than paged.
    static let maxTracksPerLanguage = 3

    /// Subtitle requests run on a shorter leash than stream resolution — they
    /// enhance playback rather than gate it, and a hanging addon must not hold
    /// the player's start for the full default timeout.
    private static let requestTimeout: TimeInterval = 10

    /// One subtitle source to query: an addon client, optionally gated on its
    /// manifest declaring the `subtitles` resource for the requested content
    /// (skipped for the owning addon — it produced the item, asking costs one
    /// request either way — and for the OpenSubtitles companion, whose support
    /// is known).
    private struct Source {
        let client: StremioClient
        let checkManifest: Bool
    }

    /// All external subtitle tracks for `media`, best-effort: a failing source
    /// contributes nothing (most stream-only addons 404 the `subtitles`
    /// resource), and the result is empty when `media` isn't a Stremio
    /// placeholder. Queried like the official app queries its installed
    /// addons: the owning playlist's addon, every other Stremio playlist whose
    /// manifest declares subtitle support, and the OpenSubtitles v3 companion
    /// for IMDb-keyed titles.
    static func subtitles(for media: PlayableMedia, container: ModelContainer) async -> [ExternalSubtitle] {
        guard let (type, id) = StremioLink.decode(media.url) else { return [] }

        var sources: [Source] = []
        let owning = DeferredStreamLink.owningPlaylist(of: media.contentRef, container: container)
        if let owning {
            sources.append(Source(
                client: StremioClient(configuration: StremioClient.Configuration(playlist: owning, timeout: requestTimeout)),
                checkManifest: false
            ))
        }
        let stremioRaw = PlaylistSourceType.stremio.rawValue
        let owningId = owning?.id ?? UUID()
        let context = ModelContext(container)
        let others = (try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.sourceTypeRaw == stremioRaw && $0.id != owningId })
        )) ?? []
        sources += others.map { playlist in
            Source(
                client: StremioClient(configuration: StremioClient.Configuration(playlist: playlist, timeout: requestTimeout)),
                checkManifest: true
            )
        }
        if id.hasPrefix("tt") {
            sources.append(Source(
                client: StremioClient(configuration: StremioClient.Configuration(
                    manifestURL: StremioClient.openSubtitlesManifestURL, timeout: requestTimeout
                )),
                checkManifest: false
            ))
        }

        let prefix = StremioStreamResolver.idPrefix(of: id)
        let lists = await withTaskGroup(of: (Int, [StremioSubtitle]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    if source.checkManifest {
                        guard let manifest = try? await source.client.getManifest(),
                              manifest.supports(resource: "subtitles", type: type, idPrefix: prefix)
                        else { return (index, []) }
                    }
                    let subtitles = try? await source.client.getSubtitles(type: type, id: id).subtitles
                    return (index, subtitles ?? [])
                }
            }
            var collected: [(Int, [StremioSubtitle])] = []
            for await entry in group {
                collected.append(entry)
            }
            // Task-group completion order is arbitrary; keep the owning
            // addon's tracks ahead, the companion's last.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return merge(lists)
    }

    /// Flattens per-source subtitle lists into the track list the player
    /// offers: http(s) URLs only, deduped across sources, capped per language
    /// so one prolific source can't swamp the menu.
    static func merge(_ lists: [[StremioSubtitle]]) -> [ExternalSubtitle] {
        var seenURLs = Set<String>()
        var perLanguage: [String: Int] = [:]
        var result: [ExternalSubtitle] = []
        for subtitle in lists.joined() {
            guard let url = URL(string: subtitle.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seenURLs.insert(subtitle.url).inserted
            else { continue }
            let count = perLanguage[subtitle.lang, default: 0]
            guard count < maxTracksPerLanguage else { continue }
            perLanguage[subtitle.lang] = count + 1
            result.append(ExternalSubtitle(id: subtitle.url, url: url, language: subtitle.lang))
        }
        return result
    }
}
