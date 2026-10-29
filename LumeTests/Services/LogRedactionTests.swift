//
//  LogRedactionTests.swift
//  LumeTests
//
//  Guards the diagnostic-log scrubber: messages interpolated with
//  `privacy: .public` (libvlc bridge, CloudKit error summaries, engine
//  errors) must never carry playlist URLs or credentials into a
//  user-exported report.
//

import Foundation
@testable import Lume
import LumeCloudKit
import Testing

struct LogRedactionTests {
    @Test func `strips xtream credentials in path`() {
        let message = "open of 'http://iptv.example.com:8080/live/myuser/mypass/1234.ts' failed"
        let scrubbed = LogRedaction.scrubURLs(in: message)
        #expect(scrubbed == "open of 'http://<redacted>' failed")
        #expect(!scrubbed.contains("myuser"))
        #expect(!scrubbed.contains("mypass"))
    }

    @Test func `strips credentials in query items`() {
        let message = "GET https://host.tld/get.php?username=alice&password=s3cret&type=m3u_plus returned 404"
        let scrubbed = LogRedaction.scrubURLs(in: message)
        #expect(scrubbed == "GET https://<redacted> returned 404")
    }

    @Test func `strips userinfo URLs`() {
        let scrubbed = LogRedaction.scrubURLs(in: "redirecting to rtsp://user:pass@10.0.0.1/stream")
        #expect(scrubbed == "redirecting to rtsp://<redacted>")
    }

    @Test func `scrubs every URL in a message`() {
        let message = "moved http://a.example/user/pass/1.ts to https://b.example/user/pass/1.ts"
        let scrubbed = LogRedaction.scrubURLs(in: message)
        #expect(scrubbed == "moved http://<redacted> to https://<redacted>")
    }

    @Test func `leaves URL free messages untouched`() {
        let message = "buffering complete (rebuffered 1.52s)"
        #expect(LogRedaction.scrubURLs(in: message) == message)
    }

    @Test func `strips webdav userinfo credentials`() {
        let message = "VLC open failed for http://bilipp:test@192.168.178.114:30035/Movies/Show.S01E01.mkv"
        let scrubbed = LogRedaction.scrubURLs(in: message)
        #expect(scrubbed == "VLC open failed for http://<redacted>")
        #expect(!scrubbed.contains("bilipp"))
        #expect(!scrubbed.contains("test@"))
    }

    @Test func `strips basic auth header value`() {
        let token = Data("bilipp:test".utf8).base64EncodedString()
        let scrubbed = LogRedaction.scrubURLs(in: "request headers: Authorization: Basic \(token)")
        #expect(scrubbed == "request headers: Authorization: Basic <redacted>")
        #expect(!scrubbed.contains(token))
    }

    @Test func `strips basic auth alongside a URL`() {
        let token = Data("alice:s3cret".utf8).base64EncodedString()
        let message = "PROPFIND https://nas.local/Movies/ Basic \(token) -> 401"
        let scrubbed = LogRedaction.scrubURLs(in: message)
        #expect(scrubbed == "PROPFIND https://<redacted> Basic <redacted> -> 401")
    }

    @Test func `leaves basic prose untouched`() {
        let message = "Basic auth failed"
        #expect(LogRedaction.scrubURLs(in: message) == message)
    }

    @Test func `describe scrubs embedded URL`() {
        let error = NSError(
            domain: "TestDomain",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "could not load http://iptv.example.com/live/u/p/9.m3u8"]
        )
        #expect(LogRedaction.describe(error) == "TestDomain 7: could not load http://<redacted>")
    }

    @Test func `strips a lume cloud bearer header`() {
        let keys = LumeCloudKeys.generate()
        // The Kit's `Credentials.authorizationHeader` format (PROTOCOL.md §2).
        let header = "Bearer acct_fictional01.\(keys.authToken)"
        let scrubbed = LogRedaction.scrubURLs(in: "request headers: Authorization: \(header)")
        #expect(scrubbed == "request headers: Authorization: Bearer <redacted>")
        #expect(!scrubbed.contains(keys.authToken))
        #expect(!scrubbed.contains("acct_fictional01"))
    }

    @Test func `strips bearer tokens in any casing`() {
        let scrubbed = LogRedaction.scrubURLs(in: "authorization: bearer eyJhbGciOiJIUzI1NiJ9.e30.c2lnbmF0dXJl -> 401")
        #expect(scrubbed == "authorization: Bearer <redacted> -> 401")
    }

    @Test func `strips bearer alongside a URL`() {
        let message = "GET https://cloud.example.test/v1/changes?since=0 Bearer abcdefgh.ijklmnop"
        #expect(LogRedaction.scrubURLs(in: message) == "GET https://<redacted> Bearer <redacted>")
    }

    @Test func `leaves bearer prose untouched`() {
        let message = "Bearer token missing"
        #expect(LogRedaction.scrubURLs(in: message) == message)
    }

    @Test func `strips a pairing deep link`() {
        let scrubbed = LogRedaction.scrubURLs(in: "opened lume://cloud/pair?code=482913")
        #expect(scrubbed == "opened lume://<redacted>")
    }

    @Test func `describe renders lume cloud errors without the server message`() {
        let error = LumeCloudError.badRequest(message: "rid 7f3a rejected for acct_fictional01")
        let described = LogRedaction.describe(error)
        #expect(described == "LumeCloudError: badRequest")
    }

    @Test func `describe follows a lume cloud transport error`() {
        let described = LogRedaction.describe(LumeCloudError.transport(URLError(.notConnectedToInternet)))
        #expect(described.hasPrefix("LumeCloudError: transport(NSURLErrorDomain -1009) ← NSURLErrorDomain -1009"))
    }
}
