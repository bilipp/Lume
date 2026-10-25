import Foundation
@testable import Lume
import Testing

/// The load request a castable item becomes: MIME type, stream type, start
/// position and the receiver-safe poster.
struct CastMediaRequestTests {
    private static func media(
        _ url: String = "http://example.com/movie/u/p/1.mp4",
        kind: PlayableMedia.Kind = .vod,
        startTime: TimeInterval = 0,
        posterURL: String? = "https://img.example.com/poster.jpg"
    ) -> PlayableMedia {
        PlayableMedia(
            id: "item",
            url: URL(string: url) ?? URL(fileURLWithPath: "/invalid"),
            title: "Title",
            subtitle: "S1 E2 · Pilot",
            posterURL: posterURL.flatMap(URL.init(string:)),
            kind: kind,
            startTime: startTime,
            contentRef: kind == .live ? .live("l1") : .episode("e1")
        )
    }

    private static func request(for media: PlayableMedia, at position: TimeInterval? = nil) throws -> CastMediaRequest {
        guard case let .castable(request) = CastStreamResolver.verdict(for: media, at: position) else {
            throw CastTestError.notCastable
        }
        return request
    }

    private enum CastTestError: Error {
        case notCastable
    }

    @Test(arguments: [
        ("http://example.com/live/u/p/1.m3u8", PlayableMedia.Kind.live, "application/x-mpegURL"),
        ("http://example.com/hls/MASTER.M3U8?token=a", .vod, "application/x-mpegURL"),
        ("https://example.com/dash/manifest.mpd", .vod, "application/dash+xml"),
        ("http://example.com/movie/u/p/1.mp4", .vod, "video/mp4"),
        ("http://example.com/movie/u/p/1.m4v", .vod, "video/mp4"),
        ("http://example.com/live/u/p/1.ts", .live, "video/mp2t"),
        ("http://example.com/series/u/p/1.mkv", .vod, "video/x-matroska"),
        ("http://example.com/clip.webm", .vod, "video/webm"),
        ("http://example.com/u/p/12345", .live, "video/mp2t"),
        ("http://example.com/play?id=9", .vod, "video/mp4")
    ])
    func `content type follows the container`(url: String, kind: PlayableMedia.Kind, expected: String) throws {
        let link = try #require(URL(string: url))
        #expect(CastMediaRequest.contentType(for: link, kind: kind) == expected)
        #expect(try Self.request(for: Self.media(url, kind: kind)).contentType == expected)
    }

    @Test(arguments: [
        (PlayableMedia.Kind.live, CastMediaRequest.StreamType.live),
        (.vod, .buffered)
    ])
    func `stream type follows the media kind`(kind: PlayableMedia.Kind, expected: CastMediaRequest.StreamType) throws {
        #expect(try Self.request(for: Self.media(kind: kind)).streamType == expected)
    }

    @Test(arguments: [
        (PlayableMedia.Kind.vod, 120.0, nil as TimeInterval?, 120.0),
        (.vod, 120, 845.5, 845.5),
        (.vod, 0, -3, 0),
        (.live, 0, 600, 0),
        (.live, 42, nil, 0)
    ])
    func `start time resumes VOD and pins live to zero`(
        kind: PlayableMedia.Kind,
        mediaStart: TimeInterval,
        position: TimeInterval?,
        expected: TimeInterval
    ) throws {
        let media = Self.media(kind: kind, startTime: mediaStart)
        #expect(try Self.request(for: media, at: position).startTime == expected)
    }

    @Test(arguments: [
        ("https://img.example.com/poster.jpg" as String?, "https://img.example.com/poster.jpg" as String?),
        ("http://img.example.com/poster.jpg", "https://img.example.com/poster.jpg"),
        ("HTTP://img.example.com:8080/p.png?x=1", "https://img.example.com:8080/p.png?x=1"),
        ("file:///var/mobile/poster.jpg", nil),
        (nil, nil)
    ])
    func `poster is offered to the receiver over https`(poster: String?, expected: String?) throws {
        let request = try Self.request(for: Self.media(posterURL: poster))
        #expect(request.posterURL?.absoluteString == expected)
    }

    @Test func `metadata and identity carry over`() throws {
        let request = try Self.request(for: Self.media())
        #expect(request.title == "Title")
        #expect(request.subtitle == "S1 E2 · Pilot")
        #expect(request.contentRef == .episode("e1"))
    }
}
