//
//  SportsSessionExpansionTests.swift
//  LumeTests
//
//  A race weekend rendered as one card per session: ids, dates, the clock-derived
//  status and the bare event id the detail fetch needs.
//

import Foundation
@testable import Lume
import Testing

struct SportsSessionExpansionTests {
    private let fp1 = Date(timeIntervalSince1970: 1_790_000_000)

    private func weekend(state: SportsFixtureState = .scheduled) -> SportsFixture {
        SportsFixture(
            id: "600",
            leagueId: "espn:racing/f1",
            leagueName: "Formula 1",
            leagueAbbreviation: "F1",
            startDate: fp1,
            status: SportsFixtureStatus(state: state),
            venue: "Baku City Circuit",
            sessions: [
                SportsSession(kind: .fp1, date: fp1),
                SportsSession(kind: .fp2, date: fp1.addingTimeInterval(4 * 3600)),
                SportsSession(kind: .fp3, date: fp1.addingTimeInterval(24 * 3600)),
                SportsSession(kind: .qualifying, date: fp1.addingTimeInterval(28 * 3600)),
                SportsSession(kind: .race, date: fp1.addingTimeInterval(50 * 3600))
            ],
            name: "Azerbaijan Grand Prix",
            shortName: "Azerbaijan GP",
            leagueLogoURL: URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/f1.png")
        )
    }

    @Test func `a weekend expands to one card per session dated at that session`() {
        let cards = weekend().expandedBySession(now: fp1.addingTimeInterval(-3600))
        #expect(cards.count == 5)
        #expect(cards.map(\.sessionKind) == [.fp1, .fp2, .fp3, .qualifying, .race])
        #expect(cards.map(\.startDate) == weekend().sessions.map(\.date))
        #expect(Set(cards.map(\.id)).count == 5)
        #expect(cards.allSatisfy { $0.eventId == "600" })
        #expect(cards.allSatisfy { $0.name == "Azerbaijan Grand Prix" && $0.sessions.count == 5 })
        #expect(cards.allSatisfy { $0.leagueLogoURL == weekend().leagueLogoURL })
        #expect(cards.allSatisfy { $0.headlineDate == $0.startDate && !$0.headlineIsOnAnotherDay })
    }

    @Test func `session status follows the clock`() {
        let duringFP2 = fp1.addingTimeInterval(4 * 3600 + 600)
        let cards = weekend().expandedBySession(now: duringFP2)
        #expect(cards.map(\.status.state) == [.final, .inProgress, .scheduled, .scheduled, .scheduled])

        let afterRaceStart = fp1.addingTimeInterval(50 * 3600 + 3600)
        #expect(weekend().expandedBySession(now: afterRaceStart).last?.status.state == .inProgress)
        let longAfterRace = fp1.addingTimeInterval(50 * 3600 + 4 * 3600)
        #expect(weekend().expandedBySession(now: longAfterRace).last?.status.state == .final)
    }

    @Test func `a finished or postponed weekend marks every session the same`() {
        let now = fp1.addingTimeInterval(4 * 3600)
        #expect(weekend(state: .final).expandedBySession(now: now).allSatisfy { $0.status.state == .final })
        #expect(weekend(state: .postponed).expandedBySession(now: now).allSatisfy { $0.status.state == .postponed })
    }

    @Test func `fixtures without sessions pass through unchanged`() {
        let match = SportsFixture(
            id: "401", leagueId: "espn:soccer/ger.1", leagueName: "Bundesliga", leagueAbbreviation: "BL",
            startDate: fp1, status: SportsFixtureStatus(state: .scheduled)
        )
        #expect(match.expandedBySession(now: fp1) == [match])
        #expect(match.eventId == "401")
    }
}
