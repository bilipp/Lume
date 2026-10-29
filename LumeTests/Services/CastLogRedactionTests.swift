//
//  CastLogRedactionTests.swift
//  LumeTests
//
//  Google Cast SDK errors can echo the content URL the receiver failed on.
//  Those URLs carry Xtream credentials in the path or WebDAV userinfo, so the
//  `LogRedaction.describe` rendering `GoogleCastProvider` logs must come out
//  scrubbed.
//

import Foundation
@testable import Lume
import Testing

struct CastLogRedactionTests {
    private static func castError(_ message: String) -> NSError {
        NSError(domain: "com.google.GCKError", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Test(arguments: [
        "Failed to load media http://iptv.example.com:8080/live/myuser/mypass/1234.m3u8",
        "Failed to load media http://iptv.example.com:8080/movie/myuser/mypass/987.mp4 (status 401)",
        "Receiver could not open https://myuser:mypass@nas.local:5006/Movies/Film.mkv"
    ])
    func `cast error detail drops embedded credentials`(message: String) {
        let detail = LogRedaction.describe(Self.castError(message))
        #expect(!detail.contains("myuser"))
        #expect(!detail.contains("mypass"))
        #expect(detail.contains("://<redacted>"))
    }

    @Test func `cast error detail keeps the surrounding message`() {
        let error = Self.castError("Failed to load media http://iptv.example.com/live/u/p/1.m3u8 (status 401)")
        #expect(LogRedaction.describe(error) == "com.google.GCKError 2: Failed to load media http://<redacted> (status 401)")
    }

    @Test func `cast error detail scrubs a basic auth credential`() {
        let token = Data("myuser:mypass".utf8).base64EncodedString()
        let detail = LogRedaction.describe(Self.castError("Authorization: Basic \(token) rejected"))
        #expect(detail == "com.google.GCKError 2: Authorization: Basic <redacted> rejected")
    }

    @Test func `described cast error is scrubbed too`() {
        let described = LogRedaction.describe(Self.castError("Failed to load http://host/live/myuser/mypass/1.ts"))
        #expect(described == "com.google.GCKError 2: Failed to load http://<redacted>")
    }
}
