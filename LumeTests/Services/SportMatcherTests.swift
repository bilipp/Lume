import Foundation
@testable import Lume
import Testing

struct SportMatcherTests {
    /// A fixed reference kickoff so the time-window assertions are deterministic.
    private let kickoff = Date(timeIntervalSince1970: 1_750_000_000) // arbitrary fixed instant

    private func fixture(home: String, away: String, kickoff: Date? = nil) -> SportFixture {
        SportFixture(
            id: "evt-\(home)-\(away)",
            leagueID: "4328",
            leagueName: "Premier League",
            homeTeam: home,
            awayTeam: away,
            kickoff: kickoff ?? self.kickoff
        )
    }

    private func candidate(_ title: String, channel: String = "sky", startOffset: TimeInterval = 0) -> EPGProgramCandidate {
        EPGProgramCandidate(
            channelId: channel,
            title: title,
            start: kickoff.addingTimeInterval(startOffset),
            end: kickoff.addingTimeInterval(startOffset + 7200)
        )
    }

    // MARK: - Token extraction

    @Test func `tokens drop short affixes and fold diacritics`() {
        #expect(SportMatcher.tokens(for: "FC Bayern München").contains("munchen"))
        #expect(!SportMatcher.tokens(for: "FC Bayern München").contains("fc"))
        // "Bayern" survives; two-letter "FC" is removed by the length filter.
        #expect(SportMatcher.tokens(for: "FC Bayern München").contains("bayern"))
    }

    @Test func `tokens keep distinguishing words for same-city clubs`() {
        let real = SportMatcher.tokens(for: "Real Madrid")
        let atletico = SportMatcher.tokens(for: "Atlético Madrid")
        #expect(real.contains("real"))
        #expect(atletico.contains("atletico"))
        // They differ, so a scored match can tell them apart.
        #expect(real != atletico)
    }

    // MARK: - Matching

    @Test func `matches a program naming both teams in the window`() throws {
        let result = SportMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Premier League: Arsenal vs Chelsea", channel: "sky-pl")]
        )
        let match = try #require(result)
        #expect(match.channelId == "sky-pl")
    }

    @Test func `does not match when only one team is present`() {
        let result = SportMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Premier League: Arsenal vs Tottenham")]
        )
        #expect(result == nil)
    }

    @Test func `ignores programs outside the kickoff window`() {
        // A program starting five hours before kickoff is well outside the lead time.
        let result = SportMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Arsenal vs Chelsea", startOffset: -5 * 3600)]
        )
        #expect(result == nil)
    }

    @Test func `allows pre-match coverage starting before kickoff`() throws {
        let result = SportMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [candidate("Live: Arsenal v Chelsea", startOffset: -90 * 60)]
        )
        #expect(try #require(result).channelId == "sky")
    }

    @Test func `picks the program closest to kickoff on a score tie`() throws {
        let result = SportMatcher.bestMatch(
            for: fixture(home: "Arsenal", away: "Chelsea"),
            in: [
                candidate("Arsenal vs Chelsea", channel: "early", startOffset: -90 * 60),
                candidate("Arsenal vs Chelsea", channel: "ontime", startOffset: 0)
            ]
        )
        #expect(try #require(result).channelId == "ontime")
    }

    @Test func `same-city clubs do not cross-match when both names are spelled out`() throws {
        // Fixture is the Madrid derby; only the derby listing names both clubs.
        let result = SportMatcher.bestMatch(
            for: fixture(home: "Atlético Madrid", away: "Real Madrid"),
            in: [
                candidate("Real Madrid vs Barcelona", channel: "wrong"),
                candidate("Atletico Madrid vs Real Madrid", channel: "right")
            ]
        )
        #expect(try #require(result).channelId == "right")
    }
}

struct SportsDBDateTests {
    @Test func `parses an ISO-8601 timestamp`() throws {
        let date = try #require(SportsDBDate.parse(timestamp: "2026-08-15T14:00:00+00:00", date: "2026-08-15", time: "14:00:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(components.year == 2026)
        #expect(components.hour == 14)
    }

    @Test func `falls back to date and time when no timestamp`() throws {
        let date = try #require(SportsDBDate.parse(timestamp: nil, date: "2026-08-15", time: "20:30:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(calendar.dateComponents([.hour, .minute], from: date).hour == 20)
    }

    @Test func `returns nil without a date`() {
        #expect(SportsDBDate.parse(timestamp: nil, date: nil, time: "20:30:00") == nil)
    }
}
