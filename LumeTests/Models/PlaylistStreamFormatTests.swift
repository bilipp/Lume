import Foundation
@testable import Lume
import Testing

/// The per-playlist HLS / MPEG-TS choice: how it maps onto built Xtream URLs
/// and how it rewrites the direct URLs an m3u playlist carries.
struct PlaylistStreamFormatTests {
    private func makeClient() -> XtreamClient {
        XtreamClient(configuration: XtreamClient.Configuration(
            serverURL: "http://example.com:8080",
            username: "testuser",
            password: "testpass",
            timeout: 30
        ))
    }

    private func makePlaylist(format: PlaylistStreamFormat = .automatic) -> Playlist {
        let playlist = Playlist(
            name: "Test",
            serverURL: "http://example.com:8080",
            username: "testuser",
            password: "testpass"
        )
        playlist.streamFormat = format
        return playlist
    }

    // MARK: - Defaults

    @Test func `defaults to automatic`() {
        #expect(makePlaylist().streamFormat == .automatic)
        #expect(PlaylistStreamFormat.automatic.xtreamFormat == nil)
    }

    @Test func `raw values are migration stable`() {
        #expect(PlaylistStreamFormat.automatic.rawValue == "automatic")
        #expect(PlaylistStreamFormat.hls.rawValue == "hls")
        #expect(PlaylistStreamFormat.mpegTS.rawValue == "mpegTS")
    }

    @Test func `unknown raw value falls back to automatic`() {
        let playlist = makePlaylist()
        playlist.streamFormatRaw = "quicktime"
        #expect(playlist.streamFormat == .automatic)
    }

    @Test func `next wraps through every case`() {
        #expect(PlaylistStreamFormat.automatic.next == .hls)
        #expect(PlaylistStreamFormat.hls.next == .mpegTS)
        #expect(PlaylistStreamFormat.mpegTS.next == .automatic)
    }

    @Test func `stalker portals cannot choose a container`() {
        let stalker = Playlist(name: "Portal", portalURL: "http://portal.example", macAddress: "00:1A:79:00:00:01")
        #expect(!stalker.supportsStreamFormatChoice)
        #expect(makePlaylist().supportsStreamFormatChoice)
    }

    // MARK: - Xtream live URLs

    @Test func `automatic keeps the historical HLS live URL`() {
        let stream = LiveStream(id: "l-1", streamId: 555, name: "Test Channel")
        let url = makeClient().buildLiveStreamURL(for: stream, playlist: makePlaylist())
        #expect(url?.absoluteString == "http://example.com:8080/live/testuser/testpass/555.m3u8")
    }

    @Test func `MPEGTS playlist builds a ts live URL`() {
        let stream = LiveStream(id: "l-2", streamId: 555, name: "Test Channel")
        let url = makeClient().buildLiveStreamURL(for: stream, playlist: makePlaylist(format: .mpegTS))
        #expect(url?.absoluteString == "http://example.com:8080/live/testuser/testpass/555.ts")
    }

    @Test func `HLS playlist builds an m3u8 live URL`() {
        let stream = LiveStream(id: "l-3", streamId: 555, name: "Test Channel")
        let url = makeClient().buildLiveStreamURL(for: stream, playlist: makePlaylist(format: .hls))
        #expect(url?.absoluteString == "http://example.com:8080/live/testuser/testpass/555.m3u8")
    }

    @Test func `explicit format argument overrides the playlist`() {
        let stream = LiveStream(id: "l-4", streamId: 555, name: "Test Channel")
        let url = makeClient().buildLiveStreamURL(for: stream, playlist: makePlaylist(format: .mpegTS), format: .m3u8)
        #expect(url?.absoluteString == "http://example.com:8080/live/testuser/testpass/555.m3u8")
    }

    // MARK: - Xtream catch-up URLs

    @Test func `catchup follows the playlist container`() throws {
        let stream = LiveStream(id: "l-5", streamId: 777, name: "Catchup Channel")
        let url = try #require(makeClient().buildCatchupURL(
            for: stream,
            playlist: makePlaylist(format: .mpegTS),
            start: Date(timeIntervalSince1970: 1_700_000_000),
            durationMinutes: 90
        ))
        #expect(url.absoluteString.hasSuffix("/777.ts"))
    }

    // MARK: - m3u direct URL rewriting

    @Test func `automatic leaves an m3u URL untouched`() throws {
        let url = try #require(URL(string: "http://host/live/user/pass/1.ts"))
        #expect(PlaylistStreamFormat.automatic.applied(to: url) == url)
    }

    @Test func `rewrites between the two live containers`() throws {
        let hlsURL = try #require(URL(string: "http://host/live/user/pass/1.m3u8"))
        let tsURL = try #require(URL(string: "http://host/live/user/pass/1.ts"))
        #expect(PlaylistStreamFormat.mpegTS.applied(to: hlsURL) == tsURL)
        #expect(PlaylistStreamFormat.hls.applied(to: tsURL) == hlsURL)
        #expect(PlaylistStreamFormat.hls.applied(to: hlsURL) == hlsURL)
    }

    @Test func `preserves the query when rewriting`() {
        let url = URL(string: "http://host/live/user/pass/1.m3u8?token=abc")
        let rewritten = url.map(PlaylistStreamFormat.mpegTS.applied(to:))
        #expect(rewritten?.absoluteString == "http://host/live/user/pass/1.ts?token=abc")
    }

    @Test func `leaves URLs that use neither container alone`() throws {
        // A bare path, a segment manifest and a VOD file must all survive
        // untouched — guessing at them would break channels that played before.
        for raw in [
            "http://host/live/user/pass/1",
            "http://host/channel/42/index.mpeg",
            "http://host/movie/user/pass/1.mkv",
            "http://host"
        ] {
            let url = try #require(URL(string: raw))
            #expect(PlaylistStreamFormat.mpegTS.applied(to: url) == url)
            #expect(PlaylistStreamFormat.hls.applied(to: url) == url)
        }
    }

    @Test func `only the filename extension is considered`() throws {
        // The dot lives in a directory component, not the filename.
        let url = try #require(URL(string: "http://host/v1.2/live/1"))
        #expect(PlaylistStreamFormat.hls.applied(to: url) == url)
    }

    // MARK: - PlayableMedia

    @Test func `m3u channel plays through the chosen container`() throws {
        let playlist = Playlist(name: "M3U", m3uURL: "http://host/list.m3u")
        playlist.streamFormat = .mpegTS
        let stream = LiveStream(id: "l-6", streamId: 1, name: "Channel")
        stream.directURL = "http://host/live/user/pass/1.m3u8"
        let media = try #require(PlayableMedia.from(stream: stream, playlist: playlist))
        #expect(media.url.absoluteString == "http://host/live/user/pass/1.ts")
    }

    @Test func `m3u channel keeps its URL on automatic`() throws {
        let playlist = Playlist(name: "M3U", m3uURL: "http://host/list.m3u")
        let stream = LiveStream(id: "l-7", streamId: 1, name: "Channel")
        stream.directURL = "http://host/live/user/pass/1.ts"
        let media = try #require(PlayableMedia.from(stream: stream, playlist: playlist))
        #expect(media.url.absoluteString == "http://host/live/user/pass/1.ts")
    }
}
