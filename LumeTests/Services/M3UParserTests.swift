//
//  M3UParserTests.swift
//  LumeTests
//
//  Parsing, classification and identity tests for the m3u pipeline.
//

import Foundation
@testable import Lume
import Testing

// MARK: - Helpers

private func writeTempPlaylist(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".m3u")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func parseAll(_ content: String, batchSize: Int = 2000) throws -> (entries: [M3UEntry], header: M3UHeader?) {
    let url = try writeTempPlaylist(content)
    defer { try? FileManager.default.removeItem(at: url) }
    var entries: [M3UEntry] = []
    var header: M3UHeader?
    try M3UParser.parse(fileURL: url, batchSize: batchSize) { header = $0 } onBatch: { entries.append(contentsOf: $0) }
    return (entries, header)
}

// MARK: - Parser

struct M3UParserTests {
    @Test func `parses attributes, group and name`() throws {
        let playlist = """
        #EXTM3U url-tvg="http://example.com/guide.xml"
        #EXTINF:-1 tvg-id="chan.1" tvg-name="Channel One" tvg-logo="http://example.com/1.png" group-title="News",Channel One HD
        http://example.com/live/1.ts
        """
        let (entries, header) = try parseAll(playlist)

        #expect(header?.epgURL == "http://example.com/guide.xml")
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.name == "Channel One HD")
        #expect(entry.tvgId == "chan.1")
        #expect(entry.logo == "http://example.com/1.png")
        #expect(entry.group == "News")
        #expect(entry.url == "http://example.com/live/1.ts")
    }

    @Test func `attribute values may contain commas`() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 group-title="News, Politics & More",The Channel
        http://example.com/live/2.ts
        """
        let entries = try parseAll(playlist).entries
        #expect(entries.first?.group == "News, Politics & More")
        #expect(entries.first?.name == "The Channel")
    }

    @Test func `handles CRLF line endings`() throws {
        let playlist = "#EXTM3U\r\n#EXTINF:-1 tvg-id=\"a\",Chan A\r\nhttp://example.com/a.ts\r\n"
        let entries = try parseAll(playlist).entries
        #expect(entries.count == 1)
        #expect(entries.first?.name == "Chan A")
        #expect(entries.first?.url == "http://example.com/a.ts")
    }

    @Test func `EXTGRP supplies the group when group-title is missing`() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1,Chan B
        #EXTGRP:Sports
        http://example.com/b.ts
        """
        let entries = try parseAll(playlist).entries
        #expect(entries.first?.group == "Sports")
    }

    @Test func `plain m3u of bare URLs yields entries`() throws {
        let playlist = """
        http://example.com/streams/first.ts
        http://example.com/streams/second.ts
        """
        let entries = try parseAll(playlist).entries
        #expect(entries.count == 2)
        #expect(entries.first?.name == "first")
    }

    @Test func `skips unknown directives and blank lines`() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1,Chan C

        #EXTVLCOPT:http-user-agent=Foo
        #KODIPROP:inputstream=adaptive
        http://example.com/c.m3u8
        """
        let entries = try parseAll(playlist).entries
        #expect(entries.count == 1)
        #expect(entries.first?.url == "http://example.com/c.m3u8")
    }

    @Test func `falls back to tvg-name when display name is missing`() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-name="Named via tvg",
        http://example.com/d.ts
        """
        let entries = try parseAll(playlist).entries
        #expect(entries.first?.name == "Named via tvg")
    }

    /// Exercises the chunked reader's carry logic: the file is much larger
    /// than one 512 KB read, so lines straddle chunk boundaries.
    @Test func `parses a large playlist across chunk boundaries`() throws {
        var content = "#EXTM3U\n"
        let count = 30000
        for index in 0 ..< count {
            content += "#EXTINF:-1 tvg-id=\"id.\(index)\" group-title=\"Group \(index % 25)\",Channel \(index)\n"
            content += "http://example.com/live/\(index).ts\n"
        }
        let url = try writeTempPlaylist(content)
        defer { try? FileManager.default.removeItem(at: url) }

        var total = 0
        var firstEntry: M3UEntry?
        var lastEntry: M3UEntry?
        let returned = try M3UParser.parse(fileURL: url, batchSize: 2000) { batch in
            if firstEntry == nil { firstEntry = batch.first }
            lastEntry = batch.last
            total += batch.count
        }

        #expect(returned == count)
        #expect(total == count)
        #expect(firstEntry?.name == "Channel 0")
        #expect(lastEntry?.name == "Channel \(count - 1)")
        #expect(lastEntry?.url == "http://example.com/live/\(count - 1).ts")
    }
}

// MARK: - Classifier

struct M3UClassifierTests {
    private func entry(name: String = "Some Channel", url: String, type: String? = nil) -> M3UEntry {
        M3UEntry(name: name, url: url, tvgId: nil, logo: nil, group: nil, type: type)
    }

    @Test func `streams without VOD markers are live`() {
        #expect(M3UClassifier.classify(entry(url: "http://example.com/live/1.ts")) == .live)
        #expect(M3UClassifier.classify(entry(url: "http://example.com/hls/chan.m3u8")) == .live)
        #expect(M3UClassifier.classify(entry(url: "http://example.com/stream/12345")) == .live)
    }

    @Test func `explicit VOD type wins over a live endpoint URL`() {
        // This provider serves movies and live channels through the same
        // `…/channel/…/index.mpeg` shape; only type="video" distinguishes them.
        let movieURL = "http://cdn.example.com:9999/channel/n36074338/index.mpeg?q=abc"
        #expect(M3UClassifier.classify(entry(url: movieURL, type: "video")) == .movie)
        #expect(M3UClassifier.classify(entry(url: movieURL, type: "VOD")) == .movie)
        // No type → the same URL is a live channel.
        #expect(M3UClassifier.classify(entry(url: movieURL)) == .live)
        // A non-VOD type (e.g. a live transcoder) falls through to live.
        #expect(M3UClassifier.classify(entry(url: movieURL, type: "flussonic")) == .live)
    }

    @Test func `episode token wins over a VOD type so series still group`() {
        let kind = M3UClassifier.classify(
            entry(name: "Dark S02E05", url: "http://example.com/channel/x/index.mpeg", type: "video")
        )
        #expect(kind == .episode(series: "Dark", season: 2, episode: 5))
    }

    @Test func `live streaming endpoints beat the VOD extension test`() {
        // Providers serve live channels through `…/index.mpeg`-style URLs; the
        // `mpeg` extension is in vodExtensions but the endpoint shape wins.
        #expect(M3UClassifier.classify(entry(url: "http://cdn.example.com:9999/channel/237e38f9/index.mpeg?q=abc")) == .live)
        #expect(M3UClassifier.classify(entry(url: "http://example.com/live/123/index.mpg")) == .live)
        #expect(M3UClassifier.classify(entry(url: "http://example.com/stream/index.mp4")) == .live)
    }

    @Test func `video file extensions and movie paths are movies`() {
        #expect(M3UClassifier.classify(entry(url: "http://example.com/vod/film.mp4")) == .movie)
        #expect(M3UClassifier.classify(entry(url: "http://example.com/vod/film.mkv?token=a.b")) == .movie)
        #expect(M3UClassifier.classify(entry(url: "http://example.com/movie/user/pass/99.avi")) == .movie)
    }

    @Test func `season episode tokens are episodes grouped by series`() {
        let kind = M3UClassifier.classify(entry(name: "Breaking Bad S05E16 Felina", url: "http://example.com/series/u/p/1.mp4"))
        #expect(kind == .episode(series: "Breaking Bad", season: 5, episode: 16))

        let dashed = M3UClassifier.classify(entry(name: "The Wire - S01 E03 - The Buys", url: "http://example.com/x.mkv"))
        #expect(dashed == .episode(series: "The Wire", season: 1, episode: 3))

        let cross = M3UClassifier.classify(entry(name: "Dark 2x05", url: "http://example.com/dark.mp4"))
        #expect(cross == .episode(series: "Dark", season: 2, episode: 5))
    }

    @Test func `token-first titles still cluster under a series name`() {
        let kind = M3UClassifier.classify(entry(name: "S01E01 Pilot", url: "http://example.com/p.mp4"))
        #expect(kind == .episode(series: "Pilot", season: 1, episode: 1))
    }

    @Test func `resolution strings are not episode tokens`() {
        #expect(M3UClassifier.classify(entry(name: "Foo TV 640x480", url: "http://example.com/foo.ts")) == .live)
        #expect(M3UClassifier.classify(entry(name: "Bar 640x480", url: "http://example.com/bar.mp4")) == .movie)
    }

    @Test func `series path without token is a movie, not live`() {
        #expect(M3UClassifier.classify(entry(name: "Some Special", url: "http://example.com/series/u/p/7.mp4")) == .movie)
    }

    @Test func `pathExtension ignores query and fragment`() {
        #expect(M3UClassifier.pathExtension(of: "http://e.com/a/b.mp4?t=1.x#f") == "mp4")
        #expect(M3UClassifier.pathExtension(of: "http://e.com/a/b") == nil)
        #expect(M3UClassifier.pathExtension(of: "http://e.com/a.b/c") == nil)
    }
}

// MARK: - Identity

struct M3UIdentityTests {
    @Test func `hashes are stable and distinct`() {
        let url = "http://example.com/live/42.ts"
        #expect(M3UIdentity.key(for: url) == M3UIdentity.key(for: url))
        #expect(M3UIdentity.key(for: url) != M3UIdentity.key(for: url + "x"))
        #expect(M3UIdentity.numericId(for: url) > 0)
        #expect(M3UIdentity.numericId(for: url) == M3UIdentity.numericId(for: url))
    }
}

// MARK: - Validation

struct M3UClientValidationTests {
    @Test func `recognizes playlist heads`() {
        #expect(M3UClient.looksLikePlaylist(Data("#EXTM3U\n#EXTINF:-1,A\nhttp://x/a.ts".utf8)))
        #expect(M3UClient.looksLikePlaylist(Data("#EXTINF:-1,A\nhttp://x/a.ts".utf8)))
        #expect(M3UClient.looksLikePlaylist(Data("http://x/a.ts\nhttp://x/b.ts".utf8)))
        #expect(!M3UClient.looksLikePlaylist(Data("<html><body>nope</body></html>".utf8)))
        #expect(!M3UClient.looksLikePlaylist(Data()))
    }

    @Test func `an enigma2 bouquet is not a playlist`() {
        let bouquet = Data("""
        #NAME 5gTvOnline
        #SERVICE 4097:0:1:0:0:0:0:0:0:0:http%3A//host%3A80/live/u/p/1.m3u8
        #DESCRIPTION Channel One
        """.utf8)
        #expect(!M3UClient.looksLikePlaylist(bouquet))
        #expect(M3UClient.looksLikeEnigma2Bouquet(bouquet))
        // A real playlist must not be misread as a bouquet.
        #expect(!M3UClient.looksLikeEnigma2Bouquet(Data("#EXTM3U\n#EXTINF:-1,A\nhttp://x/a.ts".utf8)))
        #expect(!M3UClient.looksLikeEnigma2Bouquet(Data()))
    }

    @Test func `rewrites xtream bouquet type to m3u_plus`() {
        let base = "http://host/get.php?username=u&password=p&output=ts"
        #expect(M3UClient.normalizedPlaylistURL(base + "&type=gigablue")
            == base + "&type=m3u_plus")
        #expect(M3UClient.normalizedPlaylistURL(base + "&type=dreambox")
            == base + "&type=m3u_plus")
        // Already-valid types and non-get.php URLs pass through untouched.
        let valid = base + "&type=m3u_plus"
        #expect(M3UClient.normalizedPlaylistURL(valid) == valid)
        #expect(M3UClient.normalizedPlaylistURL(base + "&type=m3u") == base + "&type=m3u")
        let plain = "http://host/playlist.m3u?type=gigablue"
        #expect(M3UClient.normalizedPlaylistURL(plain) == plain)
        #expect(M3UClient.normalizedPlaylistURL("not a url") == "not a url")
    }
}
