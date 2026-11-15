//
//  SportsReplayMetadataTests.swift
//  LumeTests
//
//  ESPN's limited response may omit games: expansion must preserve the original
//  mapping, and calendar additions must not invalidate older fixture snapshots.
//

import Foundation
@testable import Lume
import Testing

struct SportsReplayMetadataTests {
    private var league: SportsLeague {
        SportsLeague(sport: "football", slug: "nfl", name: "NFL", abbreviation: "NFL", region: .americanFootball)
    }

    @Test func `season and week labels are mapped without using results`() throws {
        let data = Data("""
        {"leagues":[{"calendar":[{"label":"Regular Season","value":"2","entries":[{"label":"Week 10","value":"10"}]}]}],
         "events":[{"id":"game","date":"2026-11-15T14:30Z","season":{"year":2026,"type":2},"week":{"number":10},
         "competitions":[{"notes":[{"headline":"Munich Game"}]}]}]}
        """.utf8)
        let response = try JSONDecoder().decode(ESPNScoreboard.self, from: data)
        let fixture = try #require(ESPNClient.mapScoreboard(response, league: league).first)
        #expect(fixture.seasonYear == 2026)
        #expect(fixture.seasonPhase == "Regular Season")
        #expect(fixture.week == 10)
        #expect(fixture.weekLabel == "Week 10")
        #expect(fixture.eventHeadline == "Munich Game")
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any])
        for key in ["seasonYear", "seasonName", "seasonPhase", "seasonPhaseID", "week", "weekLabel", "eventHeadline"] {
            old.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(SportsFixture.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.id == fixture.id)
        #expect(decoded.seasonYear == nil)
    }

    @Test func `date string calendars still decode`() throws {
        let response = try JSONDecoder().decode(ESPNScoreboard.self, from: Data(#"{"leagues":[{"calendar":["2026-11-15T00:00Z"]}],"events":[]}"#.utf8))
        #expect(response.leagues?.first?.calendar?.first?.label == nil)
    }

    @Test func `capped month unions IDs while keeping default records`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayScoreboardProtocol.self]
        let client = ESPNClient(session: URLSession(configuration: configuration))
        let fixtures = try await client.fixtures(league: league, month: DateComponents(year: 2026, month: 11))
        #expect(fixtures.count == 102)
        #expect(fixtures.first?.name == "Default")
        #expect(Set(fixtures.map(\.id)).count == 102)
        let day = try #require(ESPNClient.parseDate("2026-11-15T00:00:00Z"))
        #expect(try await client.fixtures(league: league, day: day).count == 100)
    }

    @Test func `last week is Monday to Monday across a daylight saving boundary`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        let interval = try #require(SportsReplayRange.lastWeek.interval(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.year, .month, .day], from: interval.start) == DateComponents(year: 2026, month: 10, day: 26))
        #expect(calendar.dateComponents([.year, .month, .day], from: interval.end) == DateComponents(year: 2026, month: 11, day: 2))
        #expect(interval.duration == 7 * 86400 + 3600)
    }
}

/// An isolated session protocol, so expansion tests cannot replace another
/// ESPN test's host routes while Swift Testing runs suites concurrently.
private final nonisolated class ReplayScoreboardProtocol: URLProtocol {
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let expanded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "limit" } == true
        let ids = expanded ? [99, 100, 101] : Array(0 ..< 100)
        let name = expanded ? "Expanded" : "Default"
        let events = ids.map { ["id": String($0), "name": name, "date": "2026-11-15T14:30Z"] }
        let data = (try? JSONSerialization.data(withJSONObject: ["events": events])) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
