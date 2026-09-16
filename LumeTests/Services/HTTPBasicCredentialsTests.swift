//
//  HTTPBasicCredentialsTests.swift
//  LumeTests
//
//  VLCKit has no header API, so a WebDAV stream reaches it as a userinfo MRL.
//  These guard the one place that credential shape is built: it must round-trip
//  the header, preserve the href's existing percent-encoding, and refuse to
//  produce anything at all for media that carries no headers.
//

import Foundation
@testable import Lume
import Testing

struct HTTPBasicCredentialsTests {
    private static func header(user: String, password: String) -> [String: String] {
        ["Authorization": "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()]
    }

    @Test func `decodes a basic header`() {
        let decoded = HTTPBasicCredentials.decode(Self.header(user: "bilipp", password: "test"))
        #expect(decoded?.user == "bilipp")
        #expect(decoded?.password == "test")
    }

    @Test func `decodes a password containing a colon`() {
        let decoded = HTTPBasicCredentials.decode(Self.header(user: "bilipp", password: "a:b:c"))
        #expect(decoded?.user == "bilipp")
        #expect(decoded?.password == "a:b:c")
    }

    @Test func `builds a userinfo MRL`() throws {
        let url = try #require(URL(string: "http://192.168.178.114:30035/Movies/Show.mkv"))
        let mrl = HTTPBasicCredentials.authenticatedURL(url, headers: Self.header(user: "bilipp", password: "test"))
        #expect(mrl?.absoluteString == "http://bilipp:test@192.168.178.114:30035/Movies/Show.mkv")
    }

    @Test func `preserves existing percent encoding in the path`() throws {
        let url = try #require(URL(string: "http://nas.local/Movies/Harbor.Lights.S02E01%5BIndexer.to%5D.mkv"))
        let mrl = HTTPBasicCredentials.authenticatedURL(url, headers: Self.header(user: "u", password: "p"))
        #expect(mrl?.absoluteString == "http://u:p@nas.local/Movies/Harbor.Lights.S02E01%5BIndexer.to%5D.mkv")
    }

    @Test func `percent encodes credential characters`() throws {
        let url = try #require(URL(string: "http://nas.local/a.mkv"))
        let mrl = HTTPBasicCredentials.authenticatedURL(url, headers: Self.header(user: "a@b", password: "p@ss word"))
        let mrlString = try #require(mrl?.absoluteString)
        #expect(!mrlString.contains("a@b"))
        #expect(!mrlString.contains(" "))
        let parsed = URLComponents(string: mrlString)
        #expect(parsed?.host == "nas.local")
        #expect(parsed?.user == "a@b")
        #expect(parsed?.password == "p@ss word")
    }

    @Test func `returns nil without headers`() throws {
        let url = try #require(URL(string: "http://nas.local/a.mkv"))
        #expect(HTTPBasicCredentials.authenticatedURL(url, headers: nil) == nil)
        #expect(HTTPBasicCredentials.authenticatedURL(url, headers: [:]) == nil)
        #expect(HTTPBasicCredentials.authenticatedURL(url, headers: ["X-Other": "v"]) == nil)
    }

    @Test func `refuses non http schemes`() {
        let url = URL(fileURLWithPath: "/tmp/a.mkv")
        #expect(HTTPBasicCredentials.authenticatedURL(url, headers: Self.header(user: "u", password: "p")) == nil)
    }

    @Test func `leaves a URL that already carries userinfo alone`() throws {
        let url = try #require(URL(string: "http://other:pw@nas.local/a.mkv"))
        #expect(HTTPBasicCredentials.authenticatedURL(url, headers: Self.header(user: "u", password: "p")) == nil)
    }
}
