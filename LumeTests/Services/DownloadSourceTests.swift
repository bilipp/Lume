//
//  DownloadSourceTests.swift
//  LumeTests
//
//  Which URL, headers and file name a download uses per source type, and
//  which playlists offer downloads at all.
//

import Foundation
@testable import Lume
import Testing

struct DownloadSourceTests {
    private let stored = URL(string: "http://nas.local:8096/jellyfin/Videos/abc123/stream?Static=true")!

    // MARK: - URL

    @Test func `jellyfin and Emby download through the download route`() throws {
        for type in [PlaylistSourceType.jellyfin, .emby] {
            let url = try #require(DownloadSource.url(stored: stored, sourceType: type, xtream: { nil }))
            #expect(url.absoluteString == "http://nas.local:8096/jellyfin/Items/abc123/Download")
        }
    }

    @Test func `silo, Plex, WebDAV and m3u download the stored URL`() {
        for type in [PlaylistSourceType.silo, .plex, .webdav, .m3u] {
            #expect(DownloadSource.url(stored: stored, sourceType: type, xtream: { nil }) == stored)
        }
    }

    @Test func `xtream falls back to the built URL`() throws {
        let built = try #require(URL(string: "http://provider/movie/u/p/1.mp4"))
        #expect(DownloadSource.url(stored: nil, sourceType: .xtream, xtream: { built }) == built)
    }

    @Test func `a media server row without a stored URL has nothing to download`() {
        for type in [PlaylistSourceType.jellyfin, .emby, .silo, .plex, .webdav] {
            #expect(DownloadSource.url(stored: nil, sourceType: type, xtream: { URL(string: "http://x")! }) == nil)
        }
        #expect(DownloadSource.url(stored: stored, sourceType: .stalker, xtream: { nil }) == nil)
    }

    @Test func `an unexpected Jellyfin URL shape is not downloaded`() throws {
        let other = try #require(URL(string: "http://nas.local:8096/Items/abc123/File"))
        #expect(JellyfinClient.downloadURL(forStreamURL: other) == nil)
    }

    @Test func `the download route matches the stream URL the sync stores`() throws {
        let server = try #require(URL(string: "https://media.example.com/jf"))
        let stream = try #require(JellyfinClient.streamURL(server: server, itemId: "f00d"))
        let download = try #require(JellyfinClient.downloadURL(forStreamURL: stream))
        #expect(download.absoluteString == "https://media.example.com/jf/Items/f00d/Download")
    }

    // MARK: - Request

    @Test func `the request carries the source credential as headers`() {
        let request = DownloadSource.request(url: stored, headers: ["X-Plex-Token": "secret"])
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "secret")
        #expect(DownloadSource.request(url: stored, headers: nil).allHTTPHeaderFields?.isEmpty ?? true)
    }

    // MARK: - Extension

    @Test func `container families map to a playable extension`() {
        #expect(DownloadSource.fileExtension(container: "mov,mp4,m4a,3gp,3g2,mj2") == "mp4")
        #expect(DownloadSource.fileExtension(container: "MKV") == "mkv")
        #expect(DownloadSource.fileExtension(container: "ts") == "ts")
        #expect(DownloadSource.fileExtension(container: nil) == "mp4")
        #expect(DownloadSource.fileExtension(container: "", fallback: "mkv") == "mkv")
        #expect(DownloadSource.fileExtension(container: "../evil") == "evil")
    }

    // MARK: - Response

    @Test func `only a 2xx response is kept as the file`() {
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: stored, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        #expect(DownloadSource.isAcceptable(response(200)))
        #expect(DownloadSource.isAcceptable(response(206)))
        #expect(!DownloadSource.isAcceptable(response(401)))
        #expect(!DownloadSource.isAcceptable(response(403)))
        #expect(!DownloadSource.isAcceptable(response(404)))
        #expect(DownloadSource.isAcceptable(nil))
    }

    // MARK: - Gate

    @Test func `media servers and WebDAV offer downloads`() {
        let webdav = Playlist(name: "Share", webdavURL: "http://nas.local/dav")
        let plex = Playlist(name: "Plex", plexURL: "http://nas.local:32400", accessToken: nil)
        #expect(webdav.supportsDownloads)
        #expect(plex.supportsDownloads)
        for flavor in MediaServerFlavor.allCases {
            let playlist = Playlist(
                name: "Server", mediaServerURL: "http://nas.local:8096", flavor: flavor,
                username: "u", password: "p", accessToken: "t", userId: "id"
            )
            #expect(playlist.supportsDownloads)
            playlist.resolvesSourcesOnDemand = false
            #expect(playlist.supportsDownloads)
            playlist.resolvesSourcesOnDemand = true
            #expect(!playlist.supportsDownloads)
        }
    }
}
