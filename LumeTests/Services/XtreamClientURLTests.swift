import Foundation
@testable import Lume
import Testing

struct XtreamClientURLTests {
    private func makeClient(serverURL: String = "http://example.com:8080") -> XtreamClient {
        let config = XtreamClient.Configuration(
            serverURL: serverURL,
            username: "testuser",
            password: "testpass",
            timeout: 30
        )
        return XtreamClient(configuration: config)
    }

    private func makePlaylist(
        name: String = "Test",
        serverURL: String = "http://example.com:8080",
        username: String = "testuser",
        password: String = "testpass"
    ) -> Playlist {
        Playlist(name: name, serverURL: serverURL, username: username, password: password)
    }

    // MARK: - Movie URL

    @Test func `build movie URL standard`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let movie = Movie(id: "t-123", streamId: 123, name: "Test", containerExtension: "mp4")
        let url = client.buildMovieURL(for: movie, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/movie/testuser/testpass/123.mp4")
        #expect(url == expected)
    }

    @Test func `build movie URL default extension`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let movie = Movie(id: "t-456", streamId: 456, name: "No Ext")
        let url = client.buildMovieURL(for: movie, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/movie/testuser/testpass/456.mp4")
        #expect(url == expected)
    }

    @Test func `build movie URL special chars`() {
        let client = makeClient(serverURL: "http://example.com:8080")
        let playlist = makePlaylist(username: "user@name", password: "p@ss!word")
        let movie = Movie(id: "t-789", streamId: 789, name: "Test", containerExtension: "mkv")
        let url = client.buildMovieURL(for: movie, playlist: playlist)
        #expect(url?.absoluteString.contains("user@name") == true)
        #expect(url?.absoluteString.contains("p@ss!word") == true)
    }

    // MARK: - Episode URL

    @Test func `build episode URL`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let episode = Episode(
            id: "e-1",
            episodeId: "999",
            title: "Test Episode",
            containerExtension: "mkv",
            seasonNum: 1,
            episodeNum: 1
        )
        let url = client.buildEpisodeURL(for: episode, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/series/testuser/testpass/999.mkv")
        #expect(url == expected)
    }

    @Test func `build episode URL default extension`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let episode = Episode(
            id: "e-2",
            episodeId: "888",
            title: "No Ext",
            containerExtension: "mp4",
            seasonNum: 1,
            episodeNum: 2
        )
        let url = client.buildEpisodeURL(for: episode, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/series/testuser/testpass/888.mp4")
        #expect(url == expected)
    }

    // MARK: - Live Stream URL

    @Test func `build live stream URL default format`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-1", streamId: 555, name: "Test Channel")
        let url = client.buildLiveStreamURL(for: stream, playlist: playlist)
        let expected = URL(string: "http://example.com:8080/live/testuser/testpass/555.m3u8")
        #expect(url == expected)
    }

    @Test func `build live stream URLTS format`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-2", streamId: 666, name: "TS Channel")
        let url = client.buildLiveStreamURL(for: stream, playlist: playlist, format: .tsStream)
        let expected = URL(string: "http://example.com:8080/live/testuser/testpass/666.ts")
        #expect(url == expected)
    }

    // MARK: - Catchup URL

    @Test func `build catchup URL`() {
        let client = makeClient()
        let playlist = makePlaylist()
        let stream = LiveStream(id: "l-3", streamId: 777, name: "Catchup Channel")
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)
        let url = client.buildCatchupURL(for: stream, playlist: playlist, startTime: startTime)
        #expect(url?.absoluteString.contains("timeshift") == true)
        #expect(url?.absoluteString.contains("777") == true)
        #expect(url?.absoluteString.contains("m3u8") == true)
    }

    // MARK: - Server URL trailing slash handling

    @Test func `build movie URL with trailing slash`() {
        let client = makeClient(serverURL: "http://example.com:8080/")
        let playlist = makePlaylist(serverURL: "http://example.com:8080/")
        let movie = Movie(id: "t-1", streamId: 1, name: "Test", containerExtension: "mp4")
        let url = client.buildMovieURL(for: movie, playlist: playlist)
        #expect(url?.absoluteString == "http://example.com:8080//movie/testuser/testpass/1.mp4")
    }

    @Test func `build movie URL without trailing slash`() {
        let client = makeClient(serverURL: "http://example.com:8080")
        let playlist = makePlaylist(serverURL: "http://example.com:8080")
        let movie = Movie(id: "t-1", streamId: 1, name: "Test", containerExtension: "mp4")
        let url = client.buildMovieURL(for: movie, playlist: playlist)
        #expect(url?.absoluteString == "http://example.com:8080/movie/testuser/testpass/1.mp4")
    }

    // MARK: - API URLs

    @Test func `get info URL`() {
        let client = makeClient()
        #expect(client.configuration.serverURL == "http://example.com:8080")
        #expect(client.configuration.username == "testuser")
        #expect(client.configuration.password == "testpass")
    }
}
