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
            contentRef: contentRef
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
        let directURL = movie.directURL.flatMap(URL.init(string:))
        guard let url = directURL ?? client.buildMovieURL(for: movie, playlist: playlist) else { return nil }
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
        let directURL = playlist.sourceType == .m3u
            ? episode.directSource.flatMap(URL.init(string:))
            : nil
        guard let url = directURL ?? client.buildEpisodeURL(for: episode, playlist: playlist) else { return nil }
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

    static func from(stream: LiveStream, playlist: Playlist, client: XtreamClient = XtreamClient()) -> PlayableMedia? {
        let directURL = stream.directURL.flatMap(URL.init(string:))
        guard let url = directURL ?? client.buildLiveStreamURL(for: stream, playlist: playlist) else { return nil }
        return PlayableMedia(
            id: "live-\(stream.id)",
            url: url,
            title: stream.name,
            subtitle: nil,
            posterURL: URL(string: stream.streamIcon ?? ""),
            kind: .live,
            startTime: 0,
            contentRef: .live(stream.id)
        )
    }

    /// A past programme played from the channel's catch-up archive. Modelled as
    /// VOD — the archive is a finite, seekable asset, so the player gives it a
    /// scrubber rather than the live banner, and channel surfing stays disabled.
    /// Returns `nil` for m3u streams (catch-up needs Xtream credentials) or when
    /// the channel doesn't advertise an archive.
    static func catchup(
        stream: LiveStream,
        playlist: Playlist,
        programTitle: String,
        start: Date,
        end: Date,
        client: XtreamClient = XtreamClient()
    ) -> PlayableMedia? {
        guard stream.tvArchive > 0, stream.directURL == nil else { return nil }
        let durationMinutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
        guard let url = client.buildCatchupURL(
            for: stream, playlist: playlist, start: start, durationMinutes: durationMinutes
        ) else { return nil }
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
