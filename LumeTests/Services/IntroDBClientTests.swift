//
//  IntroDBClientTests.swift
//  LumeTests
//
//  Covers `IntroDBClient.segments` — outro decoding, the degenerate-window and
//  empty-response misses, and the status-code split between a clean miss (400 /
//  404) and a real failure.
//

import Foundation
@testable import Lume
import Testing

struct IntroDBClientTests {
    /// Every IntroDB request goes to the one hardcoded host, so tests stay
    /// isolated under parallel execution by keying their stub route on a
    /// distinct `imdb_id` rather than serializing the suite.
    private let host = "api.introdb.app"

    private func makeClient(imdbId: String, status: Int = 200, body: String = "") -> IntroDBClient {
        StubURLProtocol.register(
            host: host,
            query: (name: "imdb_id", value: imdbId),
            response: .init(status: status, body: body)
        )
        return IntroDBClient(session: StubURLProtocol.makeSession(), key: nil)
    }

    @Test func `outro segment decodes with its window intact`() async throws {
        let body = """
        {"intro":{"start_sec":30,"end_sec":90},"recap":null,"outro":{"start_sec":2540,"end_sec":2620}}
        """
        let client = makeClient(imdbId: "tt0000001", body: body)
        let segments = try await client.segments(imdbId: "tt0000001", season: 1, episode: 1)

        #expect(segments?.outro == IntroSegments.Segment(start: 2540, end: 2620))
        #expect(segments?.outro?.duration == 80)
        #expect(segments?.intro == IntroSegments.Segment(start: 30, end: 90))
        #expect(segments?.recap == nil)
    }

    @Test func `degenerate window decodes to no segment`() async throws {
        let body = """
        {"intro":null,"recap":null,"outro":{"start_sec":2600,"end_sec":2600}}
        """
        let client = makeClient(imdbId: "tt0000002", body: body)
        let segments = try await client.segments(imdbId: "tt0000002", season: 1, episode: 1)

        // The only segment present collapses, so the whole lookup is a miss.
        #expect(segments == nil)
    }

    @Test func `an all-empty response is a miss, not empty segments`() async throws {
        let client = makeClient(imdbId: "tt0000003", body: #"{"intro":null,"recap":null,"outro":null}"#)
        let segments = try await client.segments(imdbId: "tt0000003", season: 1, episode: 1)

        #expect(segments == nil)
    }

    @Test func `a 400 for a non-episodic id is a clean miss`() async throws {
        let client = makeClient(imdbId: "tt0000004", status: 400, body: #"{"detail":"invalid"}"#)
        let segments = try await client.segments(imdbId: "tt0000004", season: 1, episode: 1)

        #expect(segments == nil)
    }

    @Test func `a 404 is a clean miss`() async throws {
        let client = makeClient(imdbId: "tt0000005", status: 404, body: #"{"detail":"not found"}"#)
        let segments = try await client.segments(imdbId: "tt0000005", season: 1, episode: 1)

        #expect(segments == nil)
    }

    @Test func `any other non-2xx status throws`() async {
        let client = makeClient(imdbId: "tt0000007", status: 500, body: "boom")
        do {
            _ = try await client.segments(imdbId: "tt0000007", season: 1, episode: 1)
            Issue.record("expected a server error")
        } catch let IntroDBError.serverError(status) {
            #expect(status == 500)
        } catch {
            Issue.record("expected serverError, got \(error)")
        }
    }

    @Test func `fractional seconds round-trip`() async throws {
        let body = """
        {"intro":null,"recap":null,"outro":{"start_sec":314.5,"end_sec":386.25}}
        """
        let client = makeClient(imdbId: "tt0000006", body: body)
        let segments = try await client.segments(imdbId: "tt0000006", season: 1, episode: 1)

        #expect(segments?.outro?.start == 314.5)
        #expect(segments?.outro?.end == 386.25)
    }
}
