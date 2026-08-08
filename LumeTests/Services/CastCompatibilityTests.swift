import Foundation
@testable import Lume
import Testing

/// `CastCompatibility` decides what gets handed to a Chromecast receiver before
/// the local engine is unmounted for it. Getting it wrong is invisible in the
/// app — a false "castable" shows a poster over a stream that never starts, a
/// false rejection blocks a cast that would have worked — so the rules are
/// pinned here. Pure and platform-independent: no Cast SDK involved.
struct CastCompatibilityTests {
    // MARK: - Reachability

    @Test func `a downloaded file is not castable`() {
        // The receiver fetches the stream itself and cannot reach the phone's
        // sandbox. This was the concrete silent failure: casting a downloaded
        // movie handed the TV a `file://` URL.
        let url = URL(fileURLWithPath: "/var/mobile/Containers/Data/movie.mp4")
        #expect(CastCompatibility.evaluate(url) == .rejected(.notRemote))
    }

    @Test func `an unresolved Stalker placeholder is not castable`() throws {
        let url = try #require(URL(string: "lumestalker://vod?cmd=abc"))
        #expect(CastCompatibility.evaluate(url) == .rejected(.notRemote))
    }

    // MARK: - Supported containers

    @Test(arguments: [
        ("https://host/movie.mp4", "video/mp4"),
        ("https://host/movie.m4v", "video/mp4"),
        ("http://host/live/1234.ts", "video/mp2t"),
        ("https://host/stream.m3u8", "application/x-mpegurl"),
        ("https://host/stream.mpd", "application/dash+xml"),
        ("https://host/clip.webm", "video/webm")
    ])
    func `a supported container declares its MIME type`(urlString: String, expected: String) throws {
        let verdict = try CastCompatibility.evaluate(#require(URL(string: urlString)))
        #expect(verdict == .castable(contentType: expected))
    }

    // MARK: - Unsupported containers

    @Test(arguments: ["mkv", "avi", "flv", "wmv", "vob", "mpg", "3gp"])
    func `a container the receiver cannot demux is rejected`(ext: String) throws {
        let verdict = try CastCompatibility.evaluate(#require(URL(string: "https://host/movie.\(ext)")))
        #expect(verdict == .rejected(.unsupportedContainer(ext)))
    }

    @Test func `MKV is rejected rather than mislabelled`() throws {
        // It used to be declared `video/x-matroska`, which the Default Media
        // Receiver rejects — and that rejection went unreported.
        let verdict = try CastCompatibility.evaluate(#require(URL(string: "https://host/movie.mkv")))
        #expect(!verdict.isCastable)
    }

    // MARK: - Unknown containers

    @Test func `an extensionless URL is attempted without a declared type`() throws {
        // Xtream live URLs frequently have no extension. Declaring a guessed
        // MIME type is worse than declaring none: the receiver trusts it.
        let verdict = try CastCompatibility.evaluate(#require(URL(string: "https://host/live/user/pass/1234")))
        #expect(verdict == .castable(contentType: nil))
    }

    @Test func `an unrecognised extension is attempted rather than refused`() throws {
        let verdict = try CastCompatibility.evaluate(#require(URL(string: "https://host/movie.mov")))
        #expect(verdict == .castable(contentType: nil))
    }

    @Test func `the container check ignores case`() throws {
        #expect(try CastCompatibility.evaluate(#require(URL(string: "https://host/MOVIE.MKV"))) == .rejected(.unsupportedContainer("mkv")))
        #expect(try CastCompatibility.evaluate(#require(URL(string: "https://host/MOVIE.MP4"))) == .castable(contentType: "video/mp4"))
    }

    @Test func `a query string does not confuse the container check`() throws {
        let verdict = try CastCompatibility.evaluate(#require(URL(string: "https://host/movie.mp4?token=abc123")))
        #expect(verdict == .castable(contentType: "video/mp4"))
    }
}
