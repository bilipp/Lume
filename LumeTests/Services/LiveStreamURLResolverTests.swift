import Foundation
@testable import Lume
import Testing

/// Play and Record share one live-URL answer per source type, and Play still
/// opens exactly what it did before the extraction.
struct LiveStreamURLResolverTests {
    private let client = XtreamClient(configuration: XtreamClient.Configuration(
        serverURL: "http://example.com:8080",
        username: "user",
        password: "pass",
        timeout: 30
    ))

    private func xtream(format: PlaylistStreamFormat = .automatic, allowed: [String]? = nil) -> Playlist {
        let playlist = Playlist(name: "X", serverURL: "http://example.com:8080", username: "user", password: "pass")
        playlist.streamFormat = format
        playlist.allowedOutputFormats = allowed
        return playlist
    }

    private func stream(directURL: String? = nil) -> LiveStream {
        let stream = LiveStream(id: "p-live-42", streamId: 42, name: "News")
        stream.directURL = directURL
        return stream
    }

    @Test func `xtream builds an HLS live URL on automatic`() {
        let url = LiveStreamURLResolver.playbackURL(for: stream(), playlist: xtream(), client: client)
        #expect(url?.absoluteString == "http://example.com:8080/live/user/pass/42.m3u8")
    }

    @Test func `xtream honors the playlist container`() {
        let url = LiveStreamURLResolver.playbackURL(for: stream(), playlist: xtream(format: .mpegTS), client: client)
        #expect(url?.absoluteString == "http://example.com:8080/live/user/pass/42.ts")
    }

    @Test func `xtream honors allowed output formats on automatic`() {
        let url = LiveStreamURLResolver.playbackURL(for: stream(), playlist: xtream(allowed: ["ts"]), client: client)
        #expect(url?.absoluteString == "http://example.com:8080/live/user/pass/42.ts")
    }

    @Test func `m3u plays the listed URL rewritten to the chosen container`() {
        let playlist = Playlist(name: "M", m3uURL: "http://example.com/list.m3u")
        playlist.streamFormat = .mpegTS
        let url = LiveStreamURLResolver.playbackURL(
            for: stream(directURL: "http://cdn.example.com/live/u/p/7.m3u8"),
            playlist: playlist,
            client: client
        )
        #expect(url?.absoluteString == "http://cdn.example.com/live/u/p/7.ts")
    }

    @Test func `m3u leaves a non-xtream URL alone`() {
        let playlist = Playlist(name: "M", m3uURL: "http://example.com/list.m3u")
        playlist.streamFormat = .hls
        let url = LiveStreamURLResolver.playbackURL(
            for: stream(directURL: "http://cdn.example.com/channel/index"),
            playlist: playlist,
            client: client
        )
        #expect(url?.absoluteString == "http://cdn.example.com/channel/index")
    }

    @Test func `stalker yields a placeholder that needs tap-time resolution`() throws {
        let playlist = Playlist(name: "S", portalURL: "http://portal.example", macAddress: "00:1A:79:00:00:01")
        let url = try #require(LiveStreamURLResolver.playbackURL(
            for: stream(directURL: "ffmpeg http://portal.example/ch/1"),
            playlist: playlist,
            client: client
        ))
        #expect(LiveStreamURLResolver.needsTapTimeResolution(url))
        #expect(StalkerLink.decode(url)?.type == .itv)
        #expect(StalkerLink.decode(url)?.cmd == "ffmpeg http://portal.example/ch/1")
    }

    @Test func `stalker without a command has no URL`() {
        let playlist = Playlist(name: "S", portalURL: "http://portal.example", macAddress: "00:1A:79:00:00:01")
        #expect(LiveStreamURLResolver.playbackURL(for: stream(), playlist: playlist, client: client) == nil)
    }

    @Test func `media sources fall through to the direct URL`() {
        let webdav = Playlist(name: "W", webdavURL: "https://dav.example/media")
        let plex = Playlist(name: "P", plexURL: "http://plex.local:32400", accessToken: nil)
        let direct = stream(directURL: "https://dav.example/media/a.ts")
        #expect(LiveStreamURLResolver.playbackURL(for: direct, playlist: webdav, client: client)?.absoluteString
            == "https://dav.example/media/a.ts")
        #expect(LiveStreamURLResolver.playbackURL(for: direct, playlist: plex, client: client)?.absoluteString
            == "https://dav.example/media/a.ts")
    }

    @Test func `a built URL needs no tap-time resolution`() throws {
        let url = try #require(LiveStreamURLResolver.playbackURL(for: stream(), playlist: xtream(), client: client))
        #expect(!LiveStreamURLResolver.needsTapTimeResolution(url))
    }

    @Test func `play uses the resolver URL`() {
        let playlist = xtream(format: .mpegTS)
        let live = stream()
        let media = PlayableMedia.from(stream: live, playlist: playlist, client: client)
        #expect(media?.url == LiveStreamURLResolver.playbackURL(for: live, playlist: playlist, client: client))
        #expect(media?.kind == .live)
        #expect(media?.contentRef == .live("p-live-42"))
    }
}
