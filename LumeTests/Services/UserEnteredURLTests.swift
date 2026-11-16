//
//  UserEnteredURLTests.swift
//  LumeTests
//
//  An address typed without `http://` used to fail the add-playlist
//  connection test with "unsupported URL" (-1002). These pin the scheme the
//  form now fills in, and that a URL which already has one is left alone.
//

import Foundation
@testable import Lume
import Testing

struct UserEnteredURLTests {
    @Test(arguments: [
        ("example.com:8080", "http://example.com:8080"),
        ("example.com", "http://example.com"),
        ("192.168.1.10:8096", "http://192.168.1.10:8096"),
        ("localhost:8080/", "http://localhost:8080/"),
        ("  example.com:8080 \n", "http://example.com:8080"),
        ("example.com/get.php?username=a&password=b&type=m3u_plus",
         "http://example.com/get.php?username=a&password=b&type=m3u_plus"),
        ("//example.com:8080", "http://example.com:8080")
    ])
    func `adds http to a schemeless address`(input: String, expected: String) {
        #expect(UserEnteredURL.withDefaultScheme(input) == expected)
    }

    @Test(arguments: [
        "http://example.com:8080",
        "https://example.com",
        "HTTP://Example.com:80",
        "file:///var/mobile/playlist.m3u"
    ])
    func `keeps an address that has a scheme`(input: String) {
        #expect(UserEnteredURL.withDefaultScheme(input) == input)
    }

    @Test(arguments: [
        ("http:/example.com", "http://example.com"),
        ("https:example.com:443", "https://example.com:443"),
        ("HTTP:example.com", "http://example.com")
    ])
    func `repairs a scheme with missing slashes`(input: String, expected: String) {
        #expect(UserEnteredURL.withDefaultScheme(input) == expected)
    }

    @Test func `leaves an empty field empty`() {
        #expect(UserEnteredURL.withDefaultScheme("").isEmpty)
        #expect(UserEnteredURL.withDefaultScheme("   ").isEmpty)
    }

    @Test func `the result is a URL the Xtream client can build on`() throws {
        let fixed = UserEnteredURL.withDefaultScheme("example.com:8080")
        let url = try #require(XtreamClient().buildURL(serverURL: fixed, path: "player_api.php", queryItems: []))
        #expect(url.scheme == "http")
        #expect(url.host == "example.com")
        #expect(url.port == 8080)
    }
}
