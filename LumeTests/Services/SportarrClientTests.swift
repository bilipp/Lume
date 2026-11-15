//
//  SportarrClientTests.swift
//  LumeTests
//
//  No credential or household URL belongs in the public metadata transport.
//  An off integration must stay silent, including at the client boundary.
//

import Foundation
@testable import Lume
import Testing

@Suite(.serialized)
struct SportarrClientTests {
    private let host = "sportarr.net"

    @Test func `disabled transport makes no request`() async {
        StubURLProtocol.register(host: host) { _ in .init(body: "{}") }
        let client = SportarrClient(session: StubURLProtocol.makeSession(), isEnabled: { false })
        guard case .disabled = await client.episode("ev-123456") else { Issue.record("Disabled client performed a lookup."); return }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    @Test func `enabled client uses only the fixed GET media agent route`() async throws {
        StubURLProtocol.register(host: host) { _ in .init(body: #"{"id":"ev-123456","home_team":"Lions","away_team":"Patriots"}"#) }
        let client = SportarrClient(session: StubURLProtocol.makeSession(), isEnabled: { true })
        guard case let .found(metadata) = await client.episode("ev-123456") else { Issue.record("Metadata was not decoded."); return }
        #expect(metadata.homeTeam == "Lions")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://sportarr.net/api/metadata/agents/episode/ev-123456")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Lume") == true)
    }

    @Test func `a successful HTTP response carrying error means not found`() async {
        StubURLProtocol.register(host: host) { _ in .init(body: #"{"error":"not found"}"#) }
        let client = SportarrClient(session: StubURLProtocol.makeSession(), isEnabled: { true })
        guard case .missing = await client.episode("ev-999999") else { Issue.record("Agent error must become a miss."); return }
    }

    @Test func `outage is not retried inside the client`() async {
        StubURLProtocol.register(host: host) { _ in .init(status: 503) }
        let client = SportarrClient(session: StubURLProtocol.makeSession(), isEnabled: { true })
        guard case .unavailable = await client.episode("ev-123456") else { Issue.record("Outage was not preserved."); return }
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }
}
