import Foundation
@testable import Lume
import Testing

struct PlayableMediaTests {
    private func makePlaylist() -> Playlist {
        Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
    }

    private func makeWebDAVPlaylist(username: String = "bilipp", password: String = "test") -> Playlist {
        Playlist(name: "NAS", webdavURL: "http://192.168.0.2:30035/Movies/", username: username, password: password)
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

    @Test func `catchup returns nil for m3u direct stream`() {
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-5", streamId: 302, name: "M3U", tvArchive: 1, tvArchiveDuration: 7)
        stream.directURL = "http://example.com/live/stream.m3u8"
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

    @Test func `catchup availability treats zero duration as one day`() {
        let stream = LiveStream(id: "l-8", streamId: 305, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 0)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-2 * 86400), now: now))
    }

    @Test func `catchup availability rejects channels without archive`() {
        let stream = LiveStream(id: "l-9", streamId: 306, name: "No Archive")
        let now = Date()
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
    }

    @Test func `catchup availability rejects m3u direct streams`() {
        let stream = LiveStream(id: "l-10", streamId: 307, name: "M3U",
                                tvArchive: 1, tvArchiveDuration: 7)
        stream.directURL = "http://example.com/live/stream.m3u8"
        let now = Date()
        #expect(!PlayableMedia.isCatchupAvailable(stream: stream, start: now.addingTimeInterval(-3600), now: now))
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

    // MARK: - httpHeaders (WebDAV Basic auth)

    @Test func `webdav movie carries a basic auth header and a clean url`() throws {
        let playlist = makeWebDAVPlaylist()
        let movie = Movie(id: "w-1", streamId: 0, name: "The Godfather", containerExtension: "mkv")
        movie.directURL = "http://192.168.0.2:30035/Movies/The.Godfather.mkv"

        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))
        #expect(media.url.absoluteString == "http://192.168.0.2:30035/Movies/The.Godfather.mkv")
        #expect(media.url.user == nil)
        #expect(media.url.password == nil)
        #expect(media.httpHeaders == ["Authorization": "Basic YmlsaXBwOnRlc3Q="])
    }

    @Test func `webdav episode carries a basic auth header`() throws {
        let playlist = makeWebDAVPlaylist()
        let episode = Episode(id: "w-2", episodeId: "1", title: "Pilot", containerExtension: "mkv",
                              seasonNum: 1, episodeNum: 1)
        episode.directSource = "http://192.168.0.2:30035/Movies/Show.S01E01.mkv"

        let media = try #require(PlayableMedia.from(episode: episode, playlist: playlist))
        #expect(media.httpHeaders == ["Authorization": "Basic YmlsaXBwOnRlc3Q="])
    }

    @Test func `non webdav playlist yields no headers`() throws {
        let playlist = makePlaylist()
        let movie = Movie(id: "p-3", streamId: 102, name: "Xtream Movie", containerExtension: "mp4")
        #expect(try #require(PlayableMedia.from(movie: movie, playlist: playlist)).httpHeaders == nil)

        let stream = LiveStream(id: "l-11", streamId: 202, name: "Channel")
        #expect(try #require(PlayableMedia.from(stream: stream, playlist: playlist)).httpHeaders == nil)
    }

    @Test func `anonymous webdav share yields no headers`() throws {
        let playlist = makeWebDAVPlaylist(username: "", password: "")
        let movie = Movie(id: "w-3", streamId: 0, name: "Open Share", containerExtension: "mkv")
        movie.directURL = "http://192.168.0.2:30035/Movies/Open.Share.mkv"

        #expect(try #require(PlayableMedia.from(movie: movie, playlist: playlist)).httpHeaders == nil)
    }

    @Test func `headers survive resuming and url replacement`() throws {
        let playlist = makeWebDAVPlaylist()
        let movie = Movie(id: "w-4", streamId: 0, name: "Heat", containerExtension: "mkv")
        movie.directURL = "http://192.168.0.2:30035/Movies/Heat.mkv"
        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))

        let resumed = media.resuming(at: 90)
        #expect(resumed.httpHeaders == media.httpHeaders)
        #expect(resumed.id == media.id)
        #expect(resumed.url == media.url)
        #expect(resumed.title == media.title)
        #expect(resumed.subtitle == media.subtitle)
        #expect(resumed.posterURL == media.posterURL)
        #expect(resumed.kind == media.kind)
        #expect(resumed.startTime == 90)
        #expect(resumed.contentRef == media.contentRef)
        #expect(resumed.channelScope == media.channelScope)

        let other = try #require(URL(string: "http://192.168.0.2:30035/Movies/Heat.remux.mkv"))
        let replaced = media.replacingURL(other)
        #expect(replaced.httpHeaders == media.httpHeaders)
        #expect(replaced.id == media.id)
        #expect(replaced.url == other)
        #expect(replaced.title == media.title)
        #expect(replaced.subtitle == media.subtitle)
        #expect(replaced.posterURL == media.posterURL)
        #expect(replaced.kind == media.kind)
        #expect(replaced.startTime == media.startTime)
        #expect(replaced.contentRef == media.contentRef)
        #expect(replaced.channelScope == media.channelScope)
    }

    @Test func `headers survive a codable round trip and stay out of identity`() throws {
        let playlist = makeWebDAVPlaylist()
        let movie = Movie(id: "w-5", streamId: 0, name: "Dune", containerExtension: "mkv")
        movie.directURL = "http://192.168.0.2:30035/Movies/Dune.mkv"
        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))

        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: JSONEncoder().encode(media))
        #expect(decoded == media)
        #expect(decoded.httpHeaders == media.httpHeaders)
        #expect(!media.id.contains("Basic"))
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
