import Foundation

/// A self-contained, value-type description of something playable.
/// The player view does not know about SwiftData models — it only needs this.
/// `Codable` conformance lets us pass it as the value of a SwiftUI `Window`.
struct PlayableMedia: Identifiable, Hashable, Codable {
    enum Kind: Hashable, Codable {
        case vod
        case live
    }

    enum ContentRef: Hashable, Codable {
        case movie(String)
        case episode(String)
        case live(String)
    }

    let id: String
    let url: URL
    let title: String
    let subtitle: String?
    let posterURL: URL?
    let kind: Kind
    let startTime: TimeInterval
    let contentRef: ContentRef
    /// The Live TV list this channel was launched from (Favorites, Recently
    /// Watched, or a category). `nil` where playback started outside a channel
    /// list — Home, Search, recall — in which case the player surfs the
    /// channel's own category. See `LiveChannelNavigator.adjacentMedia`.
    let channelScope: LiveChannelScope?

    nonisolated init(
        id: String,
        url: URL,
        title: String,
        subtitle: String?,
        posterURL: URL?,
        kind: Kind,
        startTime: TimeInterval,
        contentRef: ContentRef,
        channelScope: LiveChannelScope? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.kind = kind
        self.startTime = startTime
        self.contentRef = contentRef
        self.channelScope = channelScope
    }

    var isLive: Bool {
        kind == .live
    }

    /// A copy of this stream that resumes at `position` seconds. Same identity,
    /// so it's the same title for progress/NextUp — used when handing the stream
    /// to a different engine mid-playback (e.g. switching to AVPlayer to route
    /// full-screen video over AirPlay). See `FullScreenPlayerView`.
    func resuming(at position: TimeInterval) -> PlayableMedia {
        PlayableMedia(
            id: id,
            url: url,
            title: title,
            subtitle: subtitle,
            posterURL: posterURL,
            kind: kind,
            startTime: position,
            contentRef: contentRef,
            channelScope: channelScope
        )
    }

    /// Returns a copy with the playback URL replaced. Used by
    /// `StalkerStreamResolver` to swap a deferred `lumestalker://` placeholder for
    /// the real, freshly resolved stream URL while keeping the same identity.
    /// `nonisolated` so the resolver can call it off the main actor.
    nonisolated func replacingURL(_ newURL: URL) -> PlayableMedia {
        PlayableMedia(
            id: id,
            url: newURL,
            title: title,
            subtitle: subtitle,
            posterURL: posterURL,
            kind: kind,
            startTime: startTime,
            contentRef: contentRef,
            channelScope: channelScope
        )
    }
}

extension PlayableMedia {
    // m3u content carries its full playback URL on the model (`directURL` /
    // `directSource`); Xtream content builds one from credentials + stream id.
    // When a local file is available (downloaded for offline viewing), it takes
    // priority over the remote URL.

    static func from(movie: Movie, playlist: Playlist, client: XtreamClient = XtreamClient()) -> PlayableMedia? {
        // Prefer local file for offline/downloaded playback
        if let path = movie.localFileURL,
           movie.downloadStatus == .completed,
           FileManager.default.fileExists(atPath: path)
        {
            return PlayableMedia(
                id: "movie-\(movie.id)",
                url: URL(fileURLWithPath: path),
                title: movie.name,
                subtitle: movie.releaseDate,
                posterURL: URL(string: movie.streamIcon ?? ""),
                kind: .vod,
                startTime: movie.watchProgress,
                contentRef: .movie(movie.id)
            )
        }
        guard let url = vodURL(directURL: movie.directURL, playlist: playlist,
                               build: { client.buildMovieURL(for: movie, playlist: playlist) }) else { return nil }
        return PlayableMedia(
            id: "movie-\(movie.id)",
            url: url,
            title: movie.name,
            subtitle: movie.releaseDate,
            posterURL: URL(string: movie.streamIcon ?? ""),
            kind: .vod,
            startTime: movie.watchProgress,
            contentRef: .movie(movie.id)
        )
    }

    /// The playback URL for an on-demand item. For Stalker portals the stored
    /// `directURL` is a `create_link` command, wrapped in a placeholder the
    /// player resolves at playback time; otherwise it is the m3u direct URL or a
    /// built Xtream URL.
    private static func vodURL(directURL: String?, playlist: Playlist, build: () -> URL?) -> URL? {
        if playlist.sourceType == .stalker {
            guard let cmd = directURL else { return nil }
            return StalkerLink.placeholder(type: .vod, cmd: cmd)
        }
        return directURL.flatMap(URL.init(string:)) ?? build()
    }

    static func from(episode: Episode, playlist: Playlist, client: XtreamClient = XtreamClient()) -> PlayableMedia? {
        // Prefer local file for offline/downloaded playback
        if let path = episode.localFileURL,
           episode.downloadStatus == .completed,
           FileManager.default.fileExists(atPath: path)
        {
            let seriesName = episode.series?.name
            return PlayableMedia(
                id: "episode-\(episode.id)",
                url: URL(fileURLWithPath: path),
                title: seriesName ?? episode.title,
                subtitle: "S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)",
                posterURL: URL(string: episode.movieImage ?? ""),
                kind: .vod,
                startTime: episode.watchProgress,
                contentRef: .episode(episode.id)
            )
        }
        let url: URL
        switch playlist.sourceType {
        case .stalker:
            guard let cmd = episode.directSource, let placeholder = StalkerLink.placeholder(type: .vod, cmd: cmd) else { return nil }
            url = placeholder
        case .m3u:
            guard let resolved = episode.directSource.flatMap(URL.init(string:)) else { return nil }
            url = resolved
        case .xtream:
            guard let built = client.buildEpisodeURL(for: episode, playlist: playlist) else { return nil }
            url = built
        }
        let seriesName = episode.series?.name
        let subtitle = "S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)"
        return PlayableMedia(
            id: "episode-\(episode.id)",
            url: url,
            title: seriesName ?? episode.title,
            subtitle: subtitle,
            posterURL: URL(string: episode.movieImage ?? ""),
            kind: .vod,
            startTime: episode.watchProgress,
            contentRef: .episode(episode.id)
        )
    }

    /// `scope` is the channel list the viewer picked this channel from; pass it
    /// wherever playback starts from a scoped list so in-player surfing stays
    /// inside that list.
    static func from(
        stream: LiveStream,
        playlist: Playlist,
        scope: LiveChannelScope? = nil,
        client: XtreamClient = XtreamClient()
    ) -> PlayableMedia? {
        let url: URL
        if playlist.sourceType == .stalker {
            guard let cmd = stream.directURL, let placeholder = StalkerLink.placeholder(type: .itv, cmd: cmd) else { return nil }
            url = placeholder
        } else {
            // An m3u channel plays at the URL the playlist listed; the chosen
            // container rewrites it only when the provider used one of the two
            // interchangeable live endpoints. Xtream URLs are built with it.
            let directURL = stream.directURL.flatMap(URL.init(string:)).map(playlist.streamFormat.applied(to:))
            guard let resolved = directURL ?? client.buildLiveStreamURL(for: stream, playlist: playlist) else { return nil }
            url = resolved
        }
        return PlayableMedia(
            id: "live-\(stream.id)",
            url: url,
            title: stream.name,
            subtitle: nil,
            posterURL: URL(string: stream.streamIcon ?? ""),
            kind: .live,
            startTime: 0,
            contentRef: .live(stream.id),
            channelScope: scope
        )
    }

    /// The single capability rule: whether this channel can serve catch-up at
    /// all. Every affordance in the app gates on this — a tap must never reach a
    /// URL builder that then answers `nil`.
    ///
    /// Runs from lazily-rendered cell bodies, so it stays a stored-property test:
    /// the m3u import already ran `M3UCatchupURL.canBuild` and persisted the
    /// answer as `tvArchive`, and this must trust that rather than fault
    /// `catchupSource`/`directURL` and rebuild a probe URL per render.
    ///
    /// The source type needs no argument: only a buildable m3u import writes
    /// `catchupTypeRaw`, and an Xtream channel carries no `directURL`. A Stalker
    /// channel has neither — its importer writes no `tvArchive` at all and puts a
    /// `create_link` command in `directURL` (`ContentSyncManager+Stalker.swift`)
    /// rather than a playable URL.
    static func isCatchupCapable(stream: LiveStream) -> Bool {
        guard stream.tvArchive > 0 else { return false }
        return stream.catchupTypeRaw != nil || stream.directURL == nil
    }

    /// How far back to offer the archive for `stream`.
    ///
    /// `unknownArchiveDays` applies to exactly one case: an m3u
    /// channel that named a catch-up dialect but no day count, where a stored 0
    /// means "declared, depth unknown". Every other source — Xtream included —
    /// keeps the historical `max(1, …)` coercion, so an Xtream panel that
    /// advertises `tv_archive = 1` with `tv_archive_duration = 0` still offers
    /// one day and still fetches one day of guide.
    ///
    /// Tests the stored column rather than the tolerant `catchupType`
    /// accessor, so it agrees with `isCatchupCapable` row for row and stays
    /// allocation-free on the guide's per-row path (`EPGGridBuilder.rows`).
    static func archiveWindowDays(for stream: LiveStream) -> Int {
        if stream.tvArchiveDuration == 0, stream.catchupTypeRaw != nil {
            return unknownArchiveDays
        }
        return max(1, stream.tvArchiveDuration)
    }

    /// The window to offer when a channel declares catch-up but no depth
    /// (`tvArchiveDuration == 0`). The store keeps 0 to mean "declared, depth
    /// unknown" rather than inventing a provider number; this is only the
    /// browsing window we are willing to guess, and a request outside the
    /// provider's real archive fails in the normal player error path.
    static let unknownArchiveDays = 7

    /// The depth a catch-up badge may name, or `nil` for a channel whose stored
    /// duration is 0 — "declared, depth unknown", where the badge shows its
    /// glyph alone rather than claiming an archive of zero days.
    static func archiveBadgeDays(for stream: LiveStream) -> Int? {
        stream.tvArchiveDuration > 0 ? stream.tvArchiveDuration : nil
    }

    /// Ceiling on a guide's reach-back, independent of the depth a provider
    /// declares. A guide widens its `EPGListing` predicate — the largest table
    /// in the store — by that many days on the main actor, and the in-player
    /// guide re-runs the fetch on every 150 ms-debounced channel-focus move
    /// while video is playing. An m3u channel advertising `catchup-days="30"`
    /// must not turn that sweep into a month-wide fetch per row. 14 days clears
    /// every depth providers actually serve, so no real Xtream archive is
    /// narrowed by it.
    static let maxGuideArchiveDays = 14

    /// `archiveWindowDays` bounded for guide fetches. Both guides — the grid
    /// (`EPGGridBuilder.rows`) and the in-player channel browser — must use
    /// this one accessor so they agree on how far back a row offers replay.
    /// The playback-offer predicate `isCatchupAvailable` deliberately does not:
    /// a channel really does serve deeper than the guide reaches.
    static func guideArchiveWindowDays(for stream: LiveStream) -> Int {
        min(archiveWindowDays(for: stream), maxGuideArchiveDays)
    }

    /// Whether a programme that started at `start` is still replayable from the
    /// channel's catch-up archive at `now`: the channel is catch-up capable and
    /// the start lies inside the archive window.
    static func isCatchupAvailable(stream: LiveStream, start: Date, now: Date) -> Bool {
        guard isCatchupCapable(stream: stream) else { return false }
        return start >= now.addingTimeInterval(-TimeInterval(archiveWindowDays(for: stream)) * 86400)
    }

    /// A past programme played from the channel's catch-up archive. Modelled as
    /// VOD — the archive is a finite, seekable asset, so the player gives it a
    /// scrubber rather than the live banner, and channel surfing stays disabled.
    /// Returns `nil` for a channel that is not catch-up capable.
    static func catchup(
        stream: LiveStream,
        playlist: Playlist,
        programTitle: String,
        start: Date,
        end: Date,
        client: XtreamClient = XtreamClient()
    ) -> PlayableMedia? {
        guard isCatchupCapable(stream: stream) else { return nil }
        let url: URL
        switch playlist.sourceType {
        case .stalker:
            return nil
        case .m3u:
            // The **raw** `directURL`, deliberately not put through
            // `playlist.streamFormat.applied(to:)`: that rewrite swaps
            // `.m3u8` ⇄ `.ts` on live URLs and would turn a Flussonic archive
            // URL into a 404 for everyone who set the playlist to MPEG-TS.
            guard let liveURL = stream.directURL.flatMap(URL.init(string:)),
                  let type = stream.catchupType,
                  let built = M3UCatchupURL.build(
                      liveURL: liveURL, type: type, source: stream.catchupSource, start: start, end: end
                  )
            else { return nil }
            url = built
        case .xtream:
            guard let built = client.buildCatchupURL(
                for: stream, playlist: playlist, start: start, end: end
            ) else { return nil }
            url = built
        }
        return PlayableMedia(
            id: "catchup-\(stream.id)-\(Int(start.timeIntervalSince1970))",
            url: url,
            title: stream.name,
            subtitle: programTitle,
            posterURL: URL(string: stream.streamIcon ?? ""),
            kind: .vod,
            startTime: 0,
            contentRef: .live(stream.id)
        )
    }
}
