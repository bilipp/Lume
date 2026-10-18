import Foundation
@testable import Lume
import Testing

/// What may be sent to a Cast receiver: the up-front rejections, and the
/// Xtream HLS preference that replaces the played URL for a cast only.
struct CastStreamResolverTests {
    private static func media(
        _ url: String,
        kind: PlayableMedia.Kind = .vod,
        startTime: TimeInterval = 0,
        contentRef: PlayableMedia.ContentRef = .movie("m1"),
        httpHeaders: [String: String]? = nil
    ) -> PlayableMedia {
        PlayableMedia(
            id: "item",
            url: URL(string: url) ?? URL(fileURLWithPath: "/invalid"),
            title: "Title",
            subtitle: "Subtitle",
            posterURL: URL(string: "https://img.example.com/poster.jpg"),
            kind: kind,
            startTime: startTime,
            contentRef: contentRef,
            httpHeaders: httpHeaders
        )
    }

    private static let stalkerPlaceholder = StalkerLink.placeholder(type: .vod, cmd: "ffmpeg http://portal/1")?
        .absoluteString ?? ""

    // MARK: - Rejections

    @Test(arguments: [
        (media("file:///var/mobile/Downloads/movie.mp4"), CastStreamResolver.Reason.localFile),
        (media("http://rec.local/r/1.m3u8", contentRef: .recording("r1")), .recording),
        (media("http://jelly.local/Videos/1/stream.mp4", httpHeaders: ["X-Emby-Token": "t"]), .headerAuth),
        (media("http://dav.local/movie.mp4", httpHeaders: ["Authorization": "Basic x"]), .headerAuth),
        (media(stalkerPlaceholder), .needsResolution),
        (media("rtmp://live.example.com/app/stream", kind: .live), .unsupportedProtocol),
        (media("udp://239.0.0.1:1234", kind: .live), .unsupportedProtocol),
        (media("http://example.com/movie/u/p/1.avi"), .unsupportedFormat),
        (media("http://example.com/movie/u/p/1.FLV"), .unsupportedFormat),
        (media("http://example.com/movie/u/p/1.wmv"), .unsupportedFormat)
    ])
    func `uncastable media is rejected with its reason`(media: PlayableMedia, reason: CastStreamResolver.Reason) {
        #expect(CastStreamResolver.verdict(for: media) == .unsupported(reason))
    }

    @Test func `a recording is rejected even when it is also a local file`() {
        let media = Self.media("file:///tmp/rec.mp4", contentRef: .recording("r1"))
        #expect(CastStreamResolver.verdict(for: media) == .unsupported(.recording))
    }

    @Test func `a preferred URL cannot smuggle a placeholder past the check`() throws {
        let placeholder = try #require(URL(string: Self.stalkerPlaceholder))
        let media = Self.media("http://example.com/live/1.ts", kind: .live)
        #expect(CastStreamResolver.verdict(for: media, preferredURL: placeholder) == .unsupported(.needsResolution))
    }

    @Test(arguments: [
        media("http://example.com/movie/u/p/1.mp4"),
        media("https://example.com/series/u/p/1.mkv"),
        media("http://example.com/live/u/p/1.ts", kind: .live, contentRef: .live("l1")),
        media("http://cdn.example.com/channel/index", kind: .live, contentRef: .live("l1")),
        media("http://portal.example/play/live.php?stream=1&extension=ts", kind: .live, contentRef: .live("l1"))
    ])
    func `streamable http media is castable`(media: PlayableMedia) {
        guard case let .castable(request) = CastStreamResolver.verdict(for: media) else {
            Issue.record("Expected \(media.url) to be castable")
            return
        }
        #expect(request.contentURL == media.url)
        #expect(request.contentRef == media.contentRef)
    }

    @Test func `a preferred URL replaces the played one`() throws {
        let hls = try #require(URL(string: "http://example.com/live/u/p/1.m3u8"))
        let media = Self.media("http://example.com/live/u/p/1.ts", kind: .live, contentRef: .live("l1"))
        guard case let .castable(request) = CastStreamResolver.verdict(for: media, preferredURL: hls) else {
            Issue.record("Expected a castable verdict")
            return
        }
        #expect(request.contentURL == hls)
        #expect(request.contentType == "application/x-mpegURL")
    }

    @Test(arguments: CastStreamResolver.Reason.allCases)
    func `every reason has a localized explanation`(reason: CastStreamResolver.Reason) {
        let key = reason.message.key
        let missing = "\u{0}missing"
        #expect(key.hasPrefix("player.cast.unavailable."))
        #expect(Bundle.main.localizedString(forKey: key, value: missing, table: nil) != missing)
        #expect(!String(localized: reason.message).isEmpty)
    }

    // MARK: - Xtream HLS preference

    private let client = XtreamClient(configuration: XtreamClient.Configuration(
        serverURL: "http://example.com:8080",
        username: "user",
        password: "pass",
        timeout: 30
    ))

    private func xtream(format: PlaylistStreamFormat, allowed: [String]?) -> Playlist {
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

    @Test(arguments: [
        (PlaylistStreamFormat.automatic, nil as [String]?),
        (.mpegTS, nil),
        (.hls, nil),
        (.mpegTS, ["m3u8", "ts"]),
        (.automatic, ["m3u8"])
    ])
    func `xtream casts HLS whenever the account allows it`(format: PlaylistStreamFormat, allowed: [String]?) {
        let url = CastStreamResolver.preferredLiveURL(
            for: stream(), playlist: xtream(format: format, allowed: allowed), client: client
        )
        #expect(url?.absoluteString == "http://example.com:8080/live/user/pass/42.m3u8")
    }

    @Test(arguments: [PlaylistStreamFormat.automatic, .mpegTS, .hls])
    func `xtream keeps the played URL when HLS is not allowed`(format: PlaylistStreamFormat) {
        let url = CastStreamResolver.preferredLiveURL(
            for: stream(), playlist: xtream(format: format, allowed: ["ts"]), client: client
        )
        #expect(url == nil)
    }

    @Test func `a channel with its own URL keeps it`() {
        let url = CastStreamResolver.preferredLiveURL(
            for: stream(directURL: "http://cdn.example.com/live/7.ts"),
            playlist: xtream(format: .automatic, allowed: nil),
            client: client
        )
        #expect(url == nil)
    }

    @Test func `non-xtream playlists have no preferred URL`() {
        let m3u = Playlist(name: "M", m3uURL: "http://example.com/list.m3u")
        let stalker = Playlist(name: "S", portalURL: "http://portal.example", macAddress: "00:1A:79:00:00:01")
        for playlist in [m3u, stalker] {
            let url = CastStreamResolver.preferredLiveURL(for: stream(), playlist: playlist, client: client)
            #expect(url == nil)
        }
    }
}
