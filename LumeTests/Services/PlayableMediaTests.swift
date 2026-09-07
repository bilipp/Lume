import Foundation
@testable import Lume
import Testing

struct PlayableMediaTests {
    private func makePlaylist() -> Playlist {
        Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
    }

    private func makeM3UPlaylist() -> Playlist {
        Playlist(name: "M3U", m3uURL: "http://example.com/get.php?username=test&password=test")
    }

    private func makeStalkerPlaylist() -> Playlist {
        Playlist(name: "Portal", portalURL: "http://example.com/c/", macAddress: "00:1A:79:00:00:01")
    }

    // MARK: - from(movie:playlist:client:)

    @Test func `from movie creates media`() throws {
        let playlist = makePlaylist()
        let movie = Movie(id: "p-1", streamId: 100, name: "Test Movie",
                          streamIcon: "http://example.com/poster.jpg",
                          containerExtension: "mp4")
        movie.watchProgress = 30

        let media = PlayableMedia.from(movie: movie, playlist: playlist)
        let unwrapped = try #require(media)
        #expect(unwrapped.url.absoluteString == "http://example.com:8080/movie/user/pass/100.mp4")
        #expect(unwrapped.title == "Test Movie")
        #expect(unwrapped.posterURL?.absoluteString == "http://example.com/poster.jpg")
        #expect(unwrapped.kind == .vod)
        #expect(unwrapped.isLive == false)
        #expect(unwrapped.startTime == 30)
        #expect(unwrapped.contentRef == .movie(movie.id))
    }

    @Test func `from movie without poster`() {
        let playlist = makePlaylist()
        let movie = Movie(id: "p-2", streamId: 101, name: "No Poster", containerExtension: "ts")
        let media = PlayableMedia.from(movie: movie, playlist: playlist)
        #expect(media != nil)
        #expect(media?.posterURL == nil)
    }

    // MARK: - from(episode:playlist:client:)

    @Test func `from episode creates media`() throws {
        let playlist = makePlaylist()
        let series = Series(id: "s-1", seriesId: 1, name: "Test Series")
        let episode = Episode(
            id: "e-1",
            episodeId: "50",
            title: "Pilot",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1,
            series: series
        )
        episode.movieImage = "http://example.com/episode.jpg"
        episode.watchProgress = 120

        let media = try #require(PlayableMedia.from(episode: episode, playlist: playlist))
        #expect(media.url.absoluteString == "http://example.com:8080/series/user/pass/50.mkv")
        #expect(media.title == "Test Series")
        #expect(media.subtitle == "S1 E1 · Pilot")
        #expect(media.posterURL?.absoluteString == "http://example.com/episode.jpg")
        #expect(media.kind == .vod)
        #expect(media.startTime == 120)
    }

    @Test func `from episode without series name uses episode title`() throws {
        let playlist = makePlaylist()
        let episode = Episode(
            id: "e-2",
            episodeId: "51",
            title: "Standalone",
            containerExtension: "mp4",
            seasonNum: 2,
            episodeNum: 3
        )
        let media = try #require(PlayableMedia.from(episode: episode, playlist: playlist))
        #expect(media.title == "Standalone")
        #expect(media.subtitle == "S2 E3 · Standalone")
    }

    // MARK: - from(stream:playlist:client:)

    @Test func `from live stream creates media`() throws {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-1", streamId: 200, name: "News Channel",
                                streamIcon: "http://example.com/logo.png")

        let media = try #require(PlayableMedia.from(stream: stream, playlist: playlist))
        #expect(media.url.absoluteString == "http://example.com:8080/live/user/pass/200.m3u8")
        #expect(media.title == "News Channel")
        #expect(media.subtitle == nil)
        #expect(media.posterURL?.absoluteString == "http://example.com/logo.png")
        #expect(media.kind == .live)
        #expect(media.isLive == true)
        #expect(media.startTime == 0)
    }

    @Test func `from live stream without poster`() {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-2", streamId: 201, name: "Radio Stream")
        let media = PlayableMedia.from(stream: stream, playlist: playlist)
        #expect(media != nil)
        #expect(media?.posterURL == nil)
    }

    // MARK: - catchup(stream:playlist:...)

    @Test func `catchup builds seekable vod media for archive channel`() throws {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-3", streamId: 300, name: "Archive Channel",
                                streamIcon: "http://example.com/logo.png",
                                tvArchive: 1, tvArchiveDuration: 7)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)

        let media = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "Evening News", start: start, end: end
        ))
        #expect(media.kind == .vod)
        #expect(media.isLive == false)
        #expect(media.title == "Archive Channel")
        #expect(media.subtitle == "Evening News")
        #expect(media.contentRef == .live("l-3"))
        #expect(media.startTime == 0)
        #expect(media.url.absoluteString.contains("/timeshift/user/pass/60/"))
        #expect(media.url.absoluteString.hasSuffix("/300.ts"))
    }

    @Test func `catchup returns nil without archive`() {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-4", streamId: 301, name: "No Archive")
        let media = PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: Date(), end: Date().addingTimeInterval(3600)
        )
        #expect(media == nil)
    }

    @Test func `catchup returns nil for m3u channel without catchup attributes`() {
        let playlist = makeM3UPlaylist()
        let stream = LiveStream(id: "l-5", streamId: 302, name: "M3U", tvArchive: 1, tvArchiveDuration: 7)
        stream.directURL = "http://example.com/live/stream.m3u8"
        let media = PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: Date(), end: Date().addingTimeInterval(3600)
        )
        #expect(media == nil)
    }

    @Test func `catchup builds media for m3u flussonic channel`() throws {
        let playlist = makeM3UPlaylist()
        let stream = LiveStream(id: "l-5b", streamId: 303, name: "Flussonic",
                                tvArchive: 1, tvArchiveDuration: 0,
                                catchupTypeRaw: "fs")
        stream.directURL = "http://example.com/ch/video.m3u8"
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let media = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "Evening News",
            start: start, end: start.addingTimeInterval(3600)
        ))
        #expect(media.url.absoluteString == "http://example.com/ch/video-1700000000-3600.m3u8")
        #expect(media.id == "catchup-l-5b-1700000000")
        #expect(media.kind == .vod)
        #expect(media.startTime == 0)
        #expect(media.contentRef == .live("l-5b"))
        #expect(media.channelScope == nil)
    }

    @Test func `catchup ignores the playlist stream format rewrite`() throws {
        let playlist = makeM3UPlaylist()
        playlist.streamFormat = .mpegTS
        let stream = LiveStream(id: "l-5c", streamId: 304, name: "Flussonic",
                                tvArchive: 1, tvArchiveDuration: 3,
                                catchupTypeRaw: "flussonic")
        stream.directURL = "http://example.com/ch/index.m3u8"
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let media = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: start, end: start.addingTimeInterval(1800)
        ))
        #expect(media.url.absoluteString == "http://example.com/ch/index-1700000000-1800.m3u8")
    }

    @Test func `catchup returns nil for stalker channel`() {
        let playlist = makeStalkerPlaylist()
        let stream = LiveStream(id: "l-5d", streamId: 305, name: "Portal",
                                tvArchive: 1, tvArchiveDuration: 7,
                                catchupTypeRaw: "flussonic")
        stream.directURL = "ffmpeg http://localhost/ch/video.m3u8"
        let media = PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "x",
            start: Date(), end: Date().addingTimeInterval(3600)
        )
        #expect(media == nil)
    }

    // MARK: - isCatchupAvailable(stream:start:now:)

    @Test func `catchup availability inside archive window`() {
        let stream = LiveStream(id: "l-6", streamId: 303, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 7)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-3 * 86400)
        #expect(PlayableMedia.isCatchupAvailable(stream: stream, start: start, now: now))
    }

    @Test func `catchup availability rejects start beyond archive window`() {
        let stream = LiveStream(id: "l-7", streamId: 304, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 7)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-8 * 86400)
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: start, now: now))
    }

    @Test func `xtream zero duration keeps the one day window`() {
        let stream = LiveStream(id: "l-8", streamId: 305, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 0)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PlayableMedia.archiveWindowDays(for: stream) == 1)
        #expect(PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-2 * 86400), now: now))
    }

    @Test func `m3u zero duration opens the unknown depth window`() {
        let stream = LiveStream(id: "l-8b", streamId: 310, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 0,
                                catchupTypeRaw: "flussonic")
        stream.directURL = "http://example.com/ch/video.m3u8"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inside = -TimeInterval(PlayableMedia.unknownArchiveDays) * 86400 + 3600
        let outside = -TimeInterval(PlayableMedia.unknownArchiveDays) * 86400 - 3600
        #expect(PlayableMedia.archiveWindowDays(for: stream) == PlayableMedia.unknownArchiveDays)
        #expect(PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-2 * 86400), now: now))
        #expect(PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(inside), now: now))
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(outside), now: now))
    }

    @Test func `xtream declared duration keeps its own window`() {
        let stream = LiveStream(id: "l-8c", streamId: 311, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 14)
        #expect(PlayableMedia.archiveWindowDays(for: stream) == 14)
    }

    @Test func `a deep archive is clamped for the guide but not for playback`() {
        let stream = LiveStream(id: "l-8d", streamId: 312, name: "Deep Archive",
                                tvArchive: 1, tvArchiveDuration: 30)
        #expect(PlayableMedia.archiveWindowDays(for: stream) == 30)
        #expect(PlayableMedia.guideArchiveWindowDays(for: stream) == PlayableMedia.maxGuideArchiveDays)
    }

    @Test func `a fortnight archive survives the guide clamp unnarrowed`() {
        let stream = LiveStream(id: "l-8e", streamId: 313, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 14)
        #expect(PlayableMedia.guideArchiveWindowDays(for: stream) == 14)
    }

    @Test func `catchup availability rejects channels without archive`() {
        let stream = LiveStream(id: "l-9", streamId: 306, name: "No Archive")
        let now = Date()
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
    }

    @Test func `catchup availability rejects m3u channels without catchup attributes`() {
        let stream = LiveStream(id: "l-10", streamId: 307, name: "M3U",
                                tvArchive: 1, tvArchiveDuration: 7)
        stream.directURL = "http://example.com/live/stream.m3u8"
        let now = Date()
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
    }

    @Test func `catchup availability accepts m3u channels with catchup attributes`() {
        let stream = LiveStream(id: "l-10b", streamId: 308, name: "M3U Archive",
                                tvArchive: 1, tvArchiveDuration: 7,
                                catchupTypeRaw: "flussonic")
        stream.directURL = "http://example.com/ch/video.m3u8"
        let now = Date()
        #expect(PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
    }

    @Test func `catchup capability rejects stalker channels`() {
        // What the Stalker importer actually writes: no `tvArchive`, no
        // `catchupTypeRaw`, and a `create_link` command in `directURL`.
        let stream = LiveStream(id: "l-10d", streamId: 312, name: "Portal")
        stream.directURL = "ffmpeg http://localhost/ch/video.m3u8"
        #expect(!PlayableMedia.isCatchupCapable(stream: stream))
    }

    @Test func `catchup capability trusts the imported decision without rebuilding a url`() {
        // `tvArchive == 1` is only ever written for a source the importer could
        // build, so the render path must not re-derive it from the URL.
        let stream = LiveStream(id: "l-10e", streamId: 313, name: "M3U Archive",
                                tvArchive: 1, tvArchiveDuration: 7,
                                catchupTypeRaw: "default",
                                catchupSource: "plugin://foo/{utc}")
        stream.directURL = "http://example.com/live/stream.m3u8"
        #expect(PlayableMedia.isCatchupCapable(stream: stream))
    }

    // MARK: - Codable

    @Test func `playable media codable round trip`() throws {
        let media = try PlayableMedia(
            id: "test-1",
            url: #require(URL(string: "http://example.com/stream.m3u8")),
            title: "Test",
            subtitle: "S1 E1",
            posterURL: URL(string: "http://example.com/poster.jpg"),
            kind: .vod,
            startTime: 60,
            contentRef: .movie("m-1")
        )
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: data)
        #expect(decoded == media)
        #expect(decoded.id == media.id)
        #expect(decoded.title == media.title)
    }

    @Test func `playable media live codeable round trip`() throws {
        let media = try PlayableMedia(
            id: "live-1",
            url: #require(URL(string: "http://example.com/live.m3u8")),
            title: "Live",
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live("l-1")
        )
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: data)
        #expect(decoded.isLive == true)
        #expect(decoded.contentRef == .live("l-1"))
    }

    @Test func `launch scope survives a round trip and stream hand-offs`() throws {
        let media = try PlayableMedia(
            id: "live-2",
            url: #require(URL(string: "http://example.com/live.m3u8")),
            title: "Live",
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live("l-2"),
            channelScope: .favorites
        )
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: data)
        #expect(decoded.channelScope == .favorites)

        // Switching engines mid-playback and resolving a Stalker placeholder
        // both rebuild the media — the scope has to survive both.
        let other = try #require(URL(string: "http://example.com/other.m3u8"))
        #expect(media.resuming(at: 30).channelScope == .favorites)
        #expect(media.replacingURL(other).channelScope == .favorites)
    }

    // MARK: - Hashable

    @Test func `playable media hashable`() throws {
        let mediaA = try PlayableMedia(id: "x", url: #require(URL(string: "http://a.com")), title: "A", subtitle: nil, posterURL: nil, kind: .vod, startTime: 0, contentRef: .movie("m-1"))
        let mediaB = try PlayableMedia(id: "x", url: #require(URL(string: "http://b.com")), title: "B", subtitle: nil, posterURL: nil, kind: .vod, startTime: 0, contentRef: .movie("m-1"))
        let mediaC = try PlayableMedia(id: "y", url: #require(URL(string: "http://a.com")), title: "A", subtitle: nil, posterURL: nil, kind: .vod, startTime: 0, contentRef: .movie("m-2"))
        let mediaD = try PlayableMedia(id: "x", url: #require(URL(string: "http://a.com")), title: "A", subtitle: nil, posterURL: nil, kind: .vod, startTime: 0, contentRef: .movie("m-1"))
        #expect(mediaA == mediaD) // All same properties
        #expect(mediaA != mediaB) // Different url and title
        #expect(mediaA != mediaC) // Different id
        let set: Set<PlayableMedia> = [mediaA, mediaB, mediaC, mediaD]
        #expect(set.count == 3)
    }
}
