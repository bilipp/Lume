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

    @Test func `describe scrubs embedded URL`() {
        let error = NSError(
            domain: "TestDomain",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "could not load http://iptv.example.com/live/u/p/9.m3u8"]
        )
        #expect(LogRedaction.describe(error) == "TestDomain 7: could not load http://<redacted>")
    }
}
