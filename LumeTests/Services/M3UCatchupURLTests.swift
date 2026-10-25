import Foundation
@testable import Lume
import Testing

struct M3UCatchupURLTests {
    /// Frozen so every expectation below can be an exact string.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date {
        start.addingTimeInterval(3600)
    }

    private var now: Date {
        start.addingTimeInterval(7200)
    }

    private func build(
        _ live: String,
        _ type: CatchupType,
        source: String? = nil
    ) -> URL? {
        guard let liveURL = URL(string: live) else { return nil }
        return M3UCatchupURL.build(liveURL: liveURL, type: type, source: source, start: start, end: end, now: now)
    }

    // MARK: - Flussonic

    @Test func `flussonic rewrites the video filename`() {
        let url = build("http://example.com:8080/ch1/video.m3u8", .flussonic)
        #expect(url?.absoluteString == "http://example.com:8080/ch1/video-1700000000-3600.m3u8")
    }

    @Test func `flussonic rewrites the index variant and keeps the query`() {
        let url = build("http://example.com/ch1/index.m3u8?token=abc", .flussonic)
        #expect(url?.absoluteString == "http://example.com/ch1/index-1700000000-3600.m3u8?token=abc")
    }

    /// Documented limitation: `…/mpegts` has no filename to rewrite and no
    /// derivable archive path, so it stays unbuildable and gets no badge.
    @Test func `flussonic rejects a URL with no filename extension`() throws {
        #expect(build("http://example.com/ch1/mpegts", .flussonic) == nil)
        let liveURL = try #require(URL(string: "http://example.com/ch1/mpegts"))
        #expect(M3UCatchupURL.canBuild(type: .flussonic, source: nil, liveURL: liveURL) == false)
    }

    @Test func `flussonic prefers an explicit catch-up source over the filename rewrite`() {
        let url = build(
            "http://example.com/ch1/video.m3u8",
            .flussonic,
            source: "http://archive.example.com/ch1/{utc}-{duration}.m3u8"
        )
        #expect(url?.absoluteString == "http://archive.example.com/ch1/1700000000-3600.m3u8")
    }

    @Test func `flussonic resolves a relative catch-up source against the live URL`() {
        let url = build(
            "http://example.com:8080/ch1/index.m3u8?token=abc",
            .flussonic,
            source: "?utc={utc}&duration={duration}"
        )
        #expect(url?.absoluteString == "http://example.com:8080/ch1/index.m3u8?token=abc&utc=1700000000&duration=3600")
    }

    /// A source that cannot become a playable URL must not make a channel worse
    /// off than one that shipped no source at all.
    @Test func `flussonic falls back to the filename rewrite for an unusable source`() {
        let url = build("http://example.com/ch1/video.m3u8", .flussonic, source: "plugin://foo/{utc}")
        #expect(url?.absoluteString == "http://example.com/ch1/video-1700000000-3600.m3u8")
        #expect(build("http://example.com/ch1/mpegts", .flussonic, source: "plugin://foo/{utc}") == nil)
    }

    @Test func `flussonic rescues an extension-less live URL when a source is given`() {
        let url = build(
            "http://example.com/ch1/mpegts",
            .flussonic,
            source: "/ch1/archive-{utc}-{duration}.m3u8"
        )
        #expect(url?.absoluteString == "http://example.com/ch1/archive-1700000000-3600.m3u8")
    }

    @Test func `canBuild agrees with build for flussonic sources`() throws {
        let liveURL = try #require(URL(string: "http://example.com/ch1/video.m3u8"))
        let extensionLess = try #require(URL(string: "http://example.com/ch1/mpegts"))
        #expect(M3UCatchupURL.canBuild(
            type: .flussonic, source: "http://archive.example.com/{utc}.m3u8", liveURL: liveURL
        ))
        #expect(M3UCatchupURL.canBuild(type: .flussonic, source: "?utc={utc}", liveURL: liveURL))
        #expect(M3UCatchupURL.canBuild(type: .flussonic, source: "plugin://foo", liveURL: liveURL))
        #expect(M3UCatchupURL.canBuild(type: .flussonic, source: "plugin://foo", liveURL: extensionLess) == false)
        #expect(M3UCatchupURL.canBuild(type: .flussonic, source: "/dvr/{utc}.m3u8", liveURL: extensionLess))
    }

    // MARK: - Append

    @Test func `append merges onto a URL that already has a query`() {
        let url = build(
            "http://example.com/live/ch1.m3u8?token=abc",
            .append,
            source: "?utc={utc}&lutc={now}"
        )
        #expect(url?.absoluteString == "http://example.com/live/ch1.m3u8?token=abc&utc=1700000000&lutc=1700007200")
    }

    @Test func `append starts a query on a URL that has none`() {
        let url = build("http://example.com/live/ch1.m3u8", .append, source: "&utc={utc}")
        #expect(url?.absoluteString == "http://example.com/live/ch1.m3u8?utc=1700000000")
    }

    @Test func `append without a source is not buildable`() {
        #expect(build("http://example.com/live/ch1.m3u8", .append) == nil)
    }

    /// A whole URL under `catchup="append"` is a mis-tagged dialect: glued on it
    /// would become `…ch1.tshttp://archive…`, which still passes the http/host
    /// check and would badge a dead tap.
    @Test func `append reads an absolute source as a replacement URL`() throws {
        let url = build(
            "http://live.example.com/ch1.ts",
            .append,
            source: "http://archive.example.com/x-{utc}.m3u8"
        )
        #expect(url?.absoluteString == "http://archive.example.com/x-1700000000.m3u8")

        let liveURL = try #require(URL(string: "http://live.example.com/ch1.ts"))
        #expect(M3UCatchupURL.canBuild(type: .append, source: "http://archive.example.com/x.m3u8", liveURL: liveURL))
        #expect(M3UCatchupURL.canBuild(type: .append, source: "plugin://archive/{utc}", liveURL: liveURL) == false)
    }

    @Test func `append rejects a non-http absolute source`() {
        #expect(build("http://live.example.com/ch1.ts", .append, source: "plugin://archive/{utc}") == nil)
        #expect(build("http://live.example.com/ch1.ts", .append, source: "rtmp://archive/{utc}") == nil)
    }

    /// A network-path reference starts a new absolute URL too, it just borrows
    /// the live URL's scheme — so `append` must resolve it rather than glue it
    /// on, and must read it the same way `default` does.
    @Test func `append resolves a protocol-relative source instead of gluing it on`() throws {
        let url = build(
            "http://live.example.com/ch1.ts",
            .append,
            source: "//archive.example.com/x-{utc}.m3u8"
        )
        #expect(url?.absoluteString == "http://archive.example.com/x-1700000000.m3u8")

        let liveURL = try #require(URL(string: "http://live.example.com/ch1.ts"))
        #expect(M3UCatchupURL.canBuild(
            type: .append, source: "//archive.example.com/x.m3u8", liveURL: liveURL
        ))
        #expect(
            build("http://live.example.com/ch1.ts", .default, source: "//archive.example.com/x-{utc}.m3u8")
                == url
        )
    }

    // MARK: - Template expansion

    @Test func `default expands the full placeholder set`() {
        let url = build(
            "http://example.com/ch1/archive.m3u8",
            .default,
            source: "http://example.com/dvr?utc={utc}&u=${utc}&s={start}&e={end}&d={duration}&o={offset}&n={now}&l=${lutc}"
        )
        #expect(url?.absoluteString == """
        http://example.com/dvr?utc=1700000000&u=1700000000&s=1700000000&e=1700003600\
        &d=3600&o=7200&n=1700007200&l=1700007200
        """)
    }

    @Test func `shift expands the same template`() {
        let url = build(
            "http://example.com/ch1/live.ts",
            .shift,
            source: "http://example.com/shift/{utc}/{duration}.ts"
        )
        #expect(url?.absoluteString == "http://example.com/shift/1700000000/3600.ts")
    }

    @Test func `unrecognised placeholders are left untouched`() throws {
        let url = try #require(build(
            "http://example.com/ch1/live.ts",
            .default,
            source: "http://example.com/dvr?u={utc}&x={bogus}"
        ))
        let string = url.absoluteString
        #expect(string.contains("u=1700000000"))
        // `URL(string:)` percent-encodes the braces it is handed; either
        // spelling means the placeholder reached the provider unchanged.
        #expect(string.contains("x=%7Bbogus%7D") || string.contains("x={bogus}"))
    }

    // MARK: - Relative catch-up sources

    @Test func `default merges a bare-query source onto the live URL`() {
        let url = build(
            "http://example.com/live/ch1.m3u8?token=abc",
            .default,
            source: "?utc={utc}&lutc={now}"
        )
        #expect(url?.absoluteString == "http://example.com/live/ch1.m3u8?token=abc&utc=1700000000&lutc=1700007200")
    }

    @Test func `default resolves a leading-slash source against the live host`() {
        let url = build(
            "http://example.com:8080/live/ch1.m3u8",
            .default,
            source: "/dvr/ch1-{utc}-{duration}.m3u8"
        )
        #expect(url?.absoluteString == "http://example.com:8080/dvr/ch1-1700000000-3600.m3u8")
    }

    @Test func `default rejects a non-http source`() {
        #expect(build("http://example.com/live/ch1.m3u8", .default, source: "plugin://foo/{utc}") == nil)
        #expect(build("http://example.com/live/ch1.m3u8", .default, source: "rtmp://example.com/dvr") == nil)
    }

    /// Without a positive shape test these resolve against the live URL into
    /// `http://example.com/garbage` — absolute, http, hosted, and so a badge on
    /// a channel whose catch-up tap 404s.
    @Test func `default rejects a scheme-less source that is not a relative path`() {
        #expect(build("http://example.com/live/ch1.m3u8", .default, source: "garbage") == nil)
        #expect(build("http://example.com/live/ch1.m3u8", .default, source: "not a url") == nil)
        #expect(build("http://example.com/live/ch1.m3u8", .default, source: "://{utc}") == nil)
    }

    @Test func `default resolves dot-relative sources against the live URL`() {
        let url = build("http://example.com/live/ch1.m3u8", .default, source: "./dvr-{utc}.m3u8")
        #expect(url?.absoluteString == "http://example.com/live/dvr-1700000000.m3u8")
        let parent = build("http://example.com/live/ch1.m3u8", .default, source: "../dvr/{utc}.m3u8")
        #expect(parent?.absoluteString == "http://example.com/dvr/1700000000.m3u8")
    }

    @Test func `canBuild agrees with build for relative sources`() throws {
        let liveURL = try #require(URL(string: "http://example.com/live/ch1.m3u8?token=abc"))
        #expect(M3UCatchupURL.canBuild(type: .default, source: "?utc={utc}&lutc={now}", liveURL: liveURL))
        #expect(M3UCatchupURL.canBuild(type: .default, source: "/dvr/{utc}.m3u8", liveURL: liveURL))
        #expect(M3UCatchupURL.canBuild(type: .default, source: "./dvr/{utc}.m3u8", liveURL: liveURL))
        #expect(M3UCatchupURL.canBuild(type: .default, source: "plugin://foo/{utc}", liveURL: liveURL) == false)
        #expect(M3UCatchupURL.canBuild(type: .default, source: "garbage", liveURL: liveURL) == false)
        #expect(M3UCatchupURL.canBuild(type: .default, source: "not a url", liveURL: liveURL) == false)
        #expect(M3UCatchupURL.canBuild(type: .shift, source: "plugin://foo", liveURL: liveURL) == false)
    }

    // MARK: - XC

    @Test func `xc recovers credentials from the channel path`() throws {
        let url = try #require(build("http://example.com:8080/live/testuser/testpass/777.ts", .xc))
        let string = url.absoluteString
        #expect(string.hasPrefix("http://example.com:8080/timeshift/testuser/testpass/60/"))
        #expect(string.hasSuffix("/777.ts"))
        #expect(string.range(of: #"/\d{4}-\d{2}-\d{2}:\d{2}-\d{2}/777\.ts$"#, options: .regularExpression) != nil)
    }

    @Test func `xc accepts the live-less path shape and keeps the container`() throws {
        let url = try #require(build("http://example.com/testuser/testpass/778.m3u8", .xc))
        #expect(url.absoluteString.hasPrefix("http://example.com/timeshift/testuser/testpass/60/"))
        #expect(url.absoluteString.hasSuffix("/778.m3u8"))
    }

    /// A token query on the live URL is what a protected panel authorises the
    /// session with; losing it turns the rebuilt timeshift URL into a 403.
    @Test func `xc keeps the live URL token query and drops the fragment`() throws {
        let url = try #require(build("http://example.com:8080/live/testuser/testpass/777.ts?token=a%2Bb&sid=9#top", .xc))
        #expect(url.absoluteString.hasPrefix("http://example.com:8080/timeshift/testuser/testpass/60/"))
        #expect(url.absoluteString.hasSuffix("/777.ts?token=a%2Bb&sid=9"))
        #expect(url.fragment == nil)
    }

    @Test func `xc returns nil for a path it cannot parse`() {
        #expect(build("http://example.com/stream/777.ts", .xc) == nil)
        #expect(build("http://example.com/live/testuser/testpass/movie.ts", .xc) == nil)
    }

    // MARK: - Guards

    @Test func `non-positive duration is not buildable`() throws {
        let liveURL = try #require(URL(string: "http://example.com/ch1/video.m3u8"))
        #expect(M3UCatchupURL.build(
            liveURL: liveURL, type: .flussonic, source: nil, start: start, end: start, now: now
        ) == nil)
    }

    @Test func `a garbage dialect never reaches the builder`() {
        #expect(CatchupType.parse("garbage") == nil)
        #expect(CatchupType.parse("fs") == .flussonic)
    }

    // MARK: - canBuild

    @Test func `canBuild agrees with build`() throws {
        let flussonic = try #require(URL(string: "http://example.com/ch1/video.m3u8"))
        #expect(M3UCatchupURL.canBuild(type: .flussonic, source: nil, liveURL: flussonic))
        #expect(M3UCatchupURL.canBuild(type: .default, source: nil, liveURL: flussonic) == false)
        #expect(M3UCatchupURL.canBuild(type: .default, source: "  ", liveURL: flussonic) == false)
        #expect(M3UCatchupURL.canBuild(type: .append, source: "?utc={utc}", liveURL: flussonic))
        #expect(M3UCatchupURL.canBuild(type: .xc, source: nil, liveURL: flussonic) == false)
        #expect(try M3UCatchupURL.canBuild(
            type: .xc, source: nil, liveURL: #require(URL(string: "http://example.com/live/u/p/9.ts"))
        ))
    }
}
