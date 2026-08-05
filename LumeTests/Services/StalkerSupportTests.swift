import Foundation
@testable import Lume
import Testing

struct StalkerSupportTests {
    // MARK: - StalkerMAC

    @Test func `mac generate returns valid address`() {
        let mac = StalkerMAC.generate()
        #expect(StalkerMAC.isValid(mac))
    }

    @Test func `mac generate has correct prefix`() {
        let mac = StalkerMAC.generate()
        #expect(mac.hasPrefix(StalkerMAC.prefix))
    }

    @Test func `mac generate produces varying results`() {
        let macs = Set((0 ..< 10).map { _ in StalkerMAC.generate() })
        #expect(macs.count > 1)
    }

    @Test func `mac isValid accepts valid addresses`() {
        #expect(StalkerMAC.isValid("00:1A:79:3F:A2:0B"))
        #expect(StalkerMAC.isValid("00:1A:79:12:34:56"))
        #expect(StalkerMAC.isValid("00:1A:79:AB:CD:EF"))
        #expect(StalkerMAC.isValid("00:1a:79:ab:cd:ef"))
    }

    @Test func `mac isValid rejects invalid addresses`() {
        #expect(!StalkerMAC.isValid(""))
        #expect(!StalkerMAC.isValid("00:1A:79:3F:A2"))
        #expect(!StalkerMAC.isValid("00:1A:79:3F:A2:0B:FF"))
        #expect(!StalkerMAC.isValid("00:1A:79:3F:A2:0G"))
        #expect(!StalkerMAC.isValid("00-1A-79-3F-A2-0B"))
        #expect(!StalkerMAC.isValid("not a mac"))
    }

    // MARK: - StalkerLink

    @Test func `link placeholder builds url for itv`() throws {
        let url = try #require(StalkerLink.placeholder(type: .itv, cmd: "ffmpeg http://example.com/stream"))
        #expect(url.scheme == "lumestalker")
        #expect(url.host == "resolve")
    }

    @Test func `link placeholder builds url for vod`() throws {
        let url = try #require(StalkerLink.placeholder(type: .vod, cmd: "auto http://example.com/vod"))
        #expect(url.scheme == "lumestalker")
    }

    @Test func `link isPlaceholder detects placeholder`() throws {
        let url = try #require(StalkerLink.placeholder(type: .itv, cmd: "cmd"))
        #expect(StalkerLink.isPlaceholder(url))
    }

    @Test func `link isPlaceholder rejects regular url`() throws {
        let url = try #require(URL(string: "http://example.com/stream"))
        #expect(!StalkerLink.isPlaceholder(url))
    }

    @Test func `link decode returns correct type and cmd`() throws {
        let url = try #require(StalkerLink.placeholder(type: .vod, cmd: "auto http://example.com/vod"))
        let decoded = try #require(StalkerLink.decode(url))
        #expect(decoded.type == .vod)
        #expect(decoded.cmd == "auto http://example.com/vod")
    }

    @Test func `link decode returns nil for non placeholder`() throws {
        let url = try #require(URL(string: "http://example.com"))
        #expect(StalkerLink.decode(url) == nil)
    }

    @Test func `link resolvedURL extracts http URL`() {
        let url = StalkerLink.resolvedURL(from: "ffmpeg http://example.com/stream.ts?token=abc extra")
        #expect(url?.absoluteString == "http://example.com/stream.ts?token=abc")
    }

    @Test func `link resolvedURL extracts https URL`() {
        let url = StalkerLink.resolvedURL(from: "auto  https://cdn.example.com/vod.mp4")
        #expect(url?.absoluteString == "https://cdn.example.com/vod.mp4")
    }

    @Test func `link resolvedURL handles plain URL without prefix`() {
        let url = StalkerLink.resolvedURL(from: "http://example.com/stream.ts")
        #expect(url?.absoluteString == "http://example.com/stream.ts")
    }

    @Test func `link resolvedURL handles URL with no whitespace`() {
        let url = StalkerLink.resolvedURL(from: "https://example.com/vod.mp4")
        #expect(url?.absoluteString == "https://example.com/vod.mp4")
    }

    @Test func `link resolvedURL returns nil for empty string`() {
        let url = StalkerLink.resolvedURL(from: "")
        #expect(url == nil)
    }

    @Test func `link resolvedURL trims whitespace`() {
        let url = StalkerLink.resolvedURL(from: "  https://example.com/stream  ")
        #expect(url?.absoluteString == "https://example.com/stream")
    }

    @Test func `link forwardedQueryItems exposes embedded stream params`() {
        let cmd = "ffmpeg http://portal.example.com:80/play/live.php?" +
            "mac=00:1B:79:FA:12:C5&stream=933136&extension=ts&play_token=q0fg2wkpEy"
        let items = StalkerLink.forwardedQueryItems(from: cmd)
        #expect(items.map(\.name) == ["stream", "extension"])
        #expect(items.first { $0.name == "stream" }?.value == "933136")
        #expect(items.first { $0.name == "extension" }?.value == "ts")
    }

    @Test func `link forwardedQueryItems excludes mac and tokens`() {
        let cmd = "ffmpeg http://portal.example.com/play/live.php?mac=00:1A:79:00:00:01&play_token=abc&token=x"
        #expect(StalkerLink.forwardedQueryItems(from: cmd).isEmpty)
    }

    @Test func `link forwardedQueryItems empty for localhost ch cmd`() {
        #expect(StalkerLink.forwardedQueryItems(from: "ffmpeg http://localhost/ch/933136_").isEmpty)
    }

    @Test func `link forwardedQueryItems empty for non-url cmd`() {
        #expect(StalkerLink.forwardedQueryItems(from: "/media/12345.mpg").isEmpty)
        #expect(StalkerLink.forwardedQueryItems(from: "").isEmpty)
    }

    // MARK: - StalkerError

    @Test func `error invalidURL has description`() {
        let error = StalkerError.invalidURL
        #expect(error.errorDescription != nil)
        #expect(!error.isRetriable)
        #expect(!error.isAuthFailure)
    }

    @Test func `error networkError is retriable`() {
        let error = StalkerError.networkError(URLError(.notConnectedToInternet))
        #expect(error.isRetriable)
        #expect(!error.isAuthFailure)
    }

    @Test func `error serverError above 500 is retriable`() {
        let error = StalkerError.serverError(503)
        #expect(error.isRetriable)
        #expect(!error.isAuthFailure)
    }

    @Test func `error serverError below 500 is not retriable`() {
        let error = StalkerError.serverError(404)
        #expect(!error.isRetriable)
    }

    @Test func `error authenticationFailed is authFailure`() {
        let error = StalkerError.authenticationFailed
        #expect(!error.isRetriable)
        #expect(error.isAuthFailure)
    }

    @Test func `error handshakeFailed is authFailure`() {
        let error = StalkerError.handshakeFailed
        #expect(!error.isRetriable)
        #expect(error.isAuthFailure)
    }

    @Test func `error noStreamURL is not retriable`() {
        let error = StalkerError.noStreamURL
        #expect(!error.isRetriable)
        #expect(!error.isAuthFailure)
    }

    // MARK: - StalkerSessionStore

    @Test func `session store round trip`() async throws {
        let store = StalkerSessionStore()
        let session = try StalkerSessionStore.Session(
            token: "abc123",
            endpoint: #require(URL(string: "http://portal.example.com/stalker_portal"))
        )
        await store.store(session, for: "user:mac")
        let fetched = await store.session(for: "user:mac")
        #expect(fetched?.token == "abc123")
        #expect(fetched?.endpoint.absoluteString == "http://portal.example.com/stalker_portal")
    }

    @Test func `session store clear removes entry`() async throws {
        let store = StalkerSessionStore()
        let session = try StalkerSessionStore.Session(
            token: "xyz",
            endpoint: #require(URL(string: "http://example.com"))
        )
        await store.store(session, for: "key1")
        await store.clear("key1")
        let fetched = await store.session(for: "key1")
        #expect(fetched == nil)
    }

    @Test func `session store returns nil for unknown key`() async {
        let store = StalkerSessionStore()
        let fetched = await store.session(for: "nonexistent")
        #expect(fetched == nil)
    }

    @Test func `session store isolates sessions by key`() async throws {
        let store = StalkerSessionStore()
        let sessionA = try StalkerSessionStore.Session(token: "A", endpoint: #require(URL(string: "http://a.com")))
        let sessionB = try StalkerSessionStore.Session(token: "B", endpoint: #require(URL(string: "http://b.com")))
        await store.store(sessionA, for: "keyA")
        await store.store(sessionB, for: "keyB")
        let fetchedA = await store.session(for: "keyA")
        let fetchedB = await store.session(for: "keyB")
        #expect(fetchedA?.token == "A")
        #expect(fetchedB?.token == "B")
    }
}
