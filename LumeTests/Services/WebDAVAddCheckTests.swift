//
//  WebDAVAddCheckTests.swift
//  LumeTests
//
//  The add-playlist screen's failure copy for a WebDAV share.
//
//  Four failures need four different actions from the user — fix the password,
//  fix the path, allow local networking in the system Settings app, or point at
//  a folder that actually holds media — and only one of them is recoverable
//  from inside Lume. A `localizedDescription` collapses three of them into "it
//  failed", so this asserts they stay distinguishable.
//

import Foundation
@testable import Lume
import SwiftUI
import Testing

@MainActor
struct WebDAVAddCheckTests {
    private let localInput = WebDAVAddCheck.Input(
        url: "http://192.168.178.114:30035/Movies/", username: "bilipp", password: "test"
    )
    private let remoteInput = WebDAVAddCheck.Input(
        url: "https://dav.example.com/media/", username: "bilipp", password: "test"
    )

    private func message(_ error: Error, input: WebDAVAddCheck.Input, timedOut: Bool = false) -> String {
        WebDAVAddCheck.message(for: error, input: input, timedOut: timedOut)
    }

    private func unreachable(_ code: Int) -> WebDAVError {
        .networkError(NSError(domain: NSURLErrorDomain, code: code))
    }

    // MARK: - The four outcomes

    @Test func `wrong credentials tell the user anonymous access is an option`() {
        let copy = message(WebDAVError.unauthorized, input: localInput)
        #expect(copy.localizedCaseInsensitiveContains("username"))
        #expect(copy.localizedCaseInsensitiveContains("password"))
        // Anonymous shares exist, and a user who left credentials in by habit
        // has no other hint that emptying them is the fix.
        #expect(copy.localizedCaseInsensitiveContains("empty"))
    }

    @Test func `a plain web server sends the user to the full folder path`() {
        // The share root is not discoverable — an Apache `Alias` never appears
        // in a PROPFIND of the server root — so "just the hostname" is the
        // single most common mistake and has to be named explicitly.
        let copy = message(WebDAVError.notAWebDAVServer, input: localInput)
        #expect(copy.localizedCaseInsensitiveContains("full path"))
    }

    @Test func `an empty share sends the user to the full folder path`() {
        let copy = message(WebDAVAddCheck.AddError.emptyShare, input: localInput)
        #expect(copy.localizedCaseInsensitiveContains("empty"))
        #expect(copy.localizedCaseInsensitiveContains("full path"))
    }

    @Test func `an unreachable local host names the system Settings app`() {
        // A declined local-network prompt is indistinguishable from an
        // unreachable host, and nothing in Lume can re-request it — on tvOS
        // there is no other affordance at all.
        let copy = message(unreachable(NSURLErrorCannotConnectToHost), input: localInput)
        #expect(copy.localizedCaseInsensitiveContains("local network"))
        #expect(copy.localizedCaseInsensitiveContains("settings"))
    }

    @Test func `the four failures are four distinct messages`() {
        let copies = Set([
            message(WebDAVError.unauthorized, input: localInput),
            message(WebDAVError.notAWebDAVServer, input: localInput),
            message(WebDAVAddCheck.AddError.emptyShare, input: localInput),
            message(unreachable(NSURLErrorCannotConnectToHost), input: localInput)
        ])
        #expect(copies.count == 4)
    }

    // MARK: - Local vs. routable hosts

    @Test func `a timeout against a local address reads as the local network prompt`() {
        let copy = message(LoginView.ConnectionTimeoutError(), input: localInput, timedOut: true)
        #expect(copy.localizedCaseInsensitiveContains("local network"))
    }

    /// The local-network story is wrong for a share on the public internet:
    /// nothing in system Settings would fix it, so sending the user there is a
    /// dead end. A routable host has to fall through to the real error.
    @Test func `a timeout against a routable host does not blame the local network`() {
        let copy = message(LoginView.ConnectionTimeoutError(), input: remoteInput, timedOut: true)
        #expect(!copy.localizedCaseInsensitiveContains("local network"))
    }

    @Test func `an unreachable routable host does not blame the local network`() {
        let copy = message(unreachable(NSURLErrorCannotConnectToHost), input: remoteInput)
        #expect(!copy.localizedCaseInsensitiveContains("local network"))
    }

    @Test(arguments: [
        "http://localhost:8080/Movies/",
        "http://nas.local/Movies/",
        "http://nas/Movies/",
        "http://10.0.0.4/Movies/",
        "http://192.168.1.10:8080/Movies/",
        "http://172.16.4.2/Movies/",
        "http://172.31.255.1/Movies/"
    ])
    func `every private address range counts as local`(url: String) {
        let input = WebDAVAddCheck.Input(url: url, username: "u", password: "p")
        let copy = message(unreachable(NSURLErrorCannotConnectToHost), input: input)
        #expect(copy.localizedCaseInsensitiveContains("local network"))
    }

    /// `172.x` is only private inside 16–31; 172.15 and 172.32 are ordinary
    /// public addresses and a naive `hasPrefix("172.")` would misclassify them.
    @Test(arguments: ["http://172.15.0.1/Movies/", "http://172.32.0.1/Movies/", "http://93.184.216.34/Movies/"])
    func `addresses outside the private ranges are not local`(url: String) {
        let input = WebDAVAddCheck.Input(url: url, username: "u", password: "p")
        let copy = message(unreachable(NSURLErrorCannotConnectToHost), input: input)
        #expect(!copy.localizedCaseInsensitiveContains("local network"))
    }

    // MARK: - Verify

    @Test func `a URL with no host is rejected before any request goes out`() async throws {
        let input = WebDAVAddCheck.Input(url: "not a url", username: "", password: "")
        // `WebDAVError` wraps an `Error` in `.networkError`, so it can't be
        // `Equatable` — match the case instead of the value.
        let error = await #expect(throws: WebDAVError.self) {
            _ = try await WebDAVAddCheck.verify(input)
        }
        guard case .invalidURL = try #require(error) else {
            Issue.record("Expected .invalidURL, got \(String(describing: error))")
            return
        }
    }
}
