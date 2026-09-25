//
//  SportsLabelsTests.swift
//  LumeTests
//
//  Covers the provider-neutral labels derived from ESPN's machine fields — status
//  name, period, clock, event type id, stat key — and their fall-back to the
//  provider's English text. Labels resolve in the test host's language (English
//  on the simulator), so expectations spell the English catalogue value.
//

import Foundation
@testable import Lume
import Testing

struct SportsLabelsTests {
    private func status(
        _ name: String?,
        state: SportsFixtureState = .inProgress,
        detail: String = "",
        short: String = "",
        period: Int? = nil,
        clock: String? = nil
    ) -> SportsFixtureStatus {
        SportsFixtureStatus(state: state, detail: detail, shortDetail: short, typeName: name, period: period, clock: clock)
    }

    private func stat(_ label: String, key: String?) -> SportsTeamStat {
        SportsTeamStat(name: label, key: key, homeValue: nil, awayValue: nil, homeDisplay: "", awayDisplay: "")
    }

    private func fixture(leagueId: String) -> SportsFixture {
        SportsFixture(
            id: "1", leagueId: leagueId, leagueName: "", leagueAbbreviation: "",
            startDate: Date(), status: SportsFixtureStatus(state: .scheduled)
        )
    }

    // MARK: - Phases

    @Test func `status names map to phases, most specific name first`() {
        #expect(status("STATUS_FIRST_HALF").phase == .inProgress)
        #expect(status("STATUS_IN_PROGRESS").phase == .inProgress)
        #expect(status("STATUS_HALFTIME").phase == .halftime)
        #expect(status("STATUS_END_PERIOD").phase == .endOfPeriod)
        #expect(status("STATUS_FULL_TIME", state: .final).phase == .final)
        #expect(status("STATUS_FINAL", state: .final).phase == .final)
        #expect(status("STATUS_FINAL_AET", state: .final).phase == .finalAfterExtraTime)
        #expect(status("STATUS_FINAL_PEN", state: .final).phase == .finalAfterPenalties)
        #expect(status("STATUS_POSTPONED", state: .postponed).phase == .postponed)
        #expect(status("STATUS_CANCELED", state: .postponed).phase == .canceled)
        // "SUSPENDED" contains "PEN"; it must not read as a shootout.
        #expect(status("STATUS_SUSPENDED").phase == .suspended)
        #expect(status("STATUS_RAIN_DELAY").phase == .delayed)
    }

    @Test func `a status without a name falls back to the detail's stoppage word, then the state`() {
        #expect(status(nil, state: .postponed, detail: "Canceled").phase == .canceled)
        #expect(status(nil, state: .postponed, detail: "Postponed").phase == .postponed)
        #expect(status(nil, state: .final).phase == .final)
        #expect(status(nil, state: .inProgress, short: "45'").phase == .inProgress)
    }

    @Test func `stoppages are the postponed state`() {
        #expect(SportsStatusPhase.canceled.isStoppage)
        #expect(SportsStatusPhase.abandoned.isStoppage)
        #expect(!SportsStatusPhase.suspended.isStoppage)
        #expect(!SportsStatusPhase.final.isStoppage)
    }

    // MARK: - Live lines

    @Test func `soccer shows its running clock, or the half-time word`() {
        #expect(status("STATUS_SECOND_HALF", short: "68'", period: 2, clock: "68'").localizedLiveDetail(family: .clockOnly) == "68'")
        #expect(status("STATUS_HALFTIME", short: "HT", period: 1, clock: "45'+4'").localizedLiveDetail(family: .clockOnly) == "Half-time")
        #expect(status("STATUS_IN_PROGRESS", short: "0'", period: 1, clock: "0'").localizedLiveDetail(family: .clockOnly) == "0'")
    }

    @Test func `quarter sports pair the clock with the period`() {
        #expect(status("STATUS_IN_PROGRESS", short: "7:30 - 3rd", period: 3, clock: "7:30").localizedLiveDetail(family: .quarters) == "7:30 · 3rd Quarter")
        #expect(status("STATUS_IN_PROGRESS", period: 1, clock: "12:00").localizedLiveDetail(family: .halves) == "12:00 · 1st Half")
        #expect(status("STATUS_IN_PROGRESS", period: 2, clock: "0:12").localizedLiveDetail(family: .periods) == "0:12 · 2nd Period")
        #expect(status("STATUS_END_PERIOD", short: "End of 2nd", period: 2, clock: "0:00").localizedLiveDetail(family: .periods) == "End of 2nd Period")
    }

    @Test func `periods past regulation are overtime, then a shootout on ice`() {
        #expect(status("STATUS_IN_PROGRESS", period: 5, clock: "4:10").localizedLiveDetail(family: .quarters) == "4:10 · Overtime")
        #expect(status("STATUS_IN_PROGRESS", period: 6, clock: "4:10").localizedLiveDetail(family: .quarters) == "4:10 · Overtime 2")
        #expect(status("STATUS_IN_PROGRESS", period: 4, clock: "3:00").localizedLiveDetail(family: .periods) == "3:00 · Overtime")
        #expect(status("STATUS_IN_PROGRESS", period: 5, clock: "0:00").localizedLiveDetail(family: .periods) == "Shootout")
    }

    @Test func `baseball reads the half inning off the English detail`() {
        #expect(status("STATUS_IN_PROGRESS", detail: "Bottom 8th", period: 8, clock: "0:00").localizedLiveDetail(family: .innings) == "Bottom of the 8th")
        #expect(status("STATUS_IN_PROGRESS", detail: "Top 3rd", period: 3).localizedLiveDetail(family: .innings) == "Top of the 3rd")
        #expect(status("STATUS_IN_PROGRESS", detail: "", period: 3).localizedLiveDetail(family: .innings) == "3rd Inning")
    }

    @Test func `a status recorded without machine fields shows the provider's short detail`() {
        #expect(status(nil, short: "7:30 - 4th").localizedLiveDetail(family: .quarters) == "7:30 - 4th")
        #expect(status(nil, short: "45'").localizedLiveDetail(family: .clockOnly) == "45'")
        #expect(status(nil, short: "").localizedLiveDetail(family: .quarters) == nil)
        #expect(status(nil, state: .final, short: "FT").localizedLiveDetail(family: .clockOnly) == nil)
    }

    @Test func `race sessions have nothing to add to the badge`() {
        #expect(status(nil, state: .inProgress).localizedLiveDetail(family: .none) == nil)
    }

    // MARK: - Stoppages and endings

    @Test func `the postponed card names the kind of stoppage`() {
        #expect(status("STATUS_POSTPONED", state: .postponed).localizedStoppage == "Postponed")
        #expect(status("STATUS_CANCELED", state: .postponed).localizedStoppage == "Canceled")
        #expect(status("STATUS_ABANDONED", state: .postponed).localizedStoppage == "Abandoned")
        #expect(status(nil, state: .postponed, short: "PPD").localizedStoppage == "Postponed")
    }

    @Test func `a finished game says how it went past regulation`() {
        #expect(status("STATUS_FINAL_PEN", state: .final).localizedEndingQualifier(family: .clockOnly) == "After penalties")
        #expect(status("STATUS_FINAL_AET", state: .final).localizedEndingQualifier(family: .clockOnly) == "After extra time")
        #expect(status("STATUS_FINAL", state: .final, period: 5).localizedEndingQualifier(family: .quarters) == "After overtime")
        #expect(status("STATUS_FINAL", state: .final, period: 4).localizedEndingQualifier(family: .periods) == "After overtime")
        #expect(status("STATUS_FINAL", state: .final, period: 5).localizedEndingQualifier(family: .periods) == "After shootout")
        #expect(status("STATUS_FINAL", state: .final, period: 11).localizedEndingQualifier(family: .innings) == "After extra innings")
        #expect(status("STATUS_FINAL", state: .final, period: 4).localizedEndingQualifier(family: .quarters) == nil)
        #expect(status("STATUS_FULL_TIME", state: .final, period: 2).localizedEndingQualifier(family: .clockOnly) == nil)
        #expect(status(nil, state: .final).localizedEndingQualifier(family: .quarters) == nil)
    }

    // MARK: - Families

    @Test func `the period family follows the sport, and college basketball plays halves`() {
        #expect(fixture(leagueId: "espn:soccer/ger.1").periodFamily == .clockOnly)
        #expect(fixture(leagueId: "espn:soccer/ger.1").sport == "soccer")
        #expect(fixture(leagueId: "espn:soccer/ger.1").leagueSlug == "ger.1")
        #expect(fixture(leagueId: "espn:football/nfl").periodFamily == .quarters)
        #expect(fixture(leagueId: "espn:basketball/nba").periodFamily == .quarters)
        #expect(fixture(leagueId: "espn:basketball/mens-college-basketball").periodFamily == .halves)
        #expect(fixture(leagueId: "espn:hockey/nhl").periodFamily == .periods)
        #expect(fixture(leagueId: "espn:baseball/mlb").periodFamily == .innings)
        #expect(fixture(leagueId: "espn:racing/f1").periodFamily == .none)
        #expect(fixture(leagueId: "espn:rugby/267979").periodFamily == .clockOnly)
    }

    // MARK: - Key events and stats

    @Test func `key events are titled by type id, then by English text, else verbatim`() {
        #expect(SportsKeyEvent(clock: "44'", type: "Goal - Header", typeId: "137").localizedTitle == "Goal (header)")
        #expect(SportsKeyEvent(clock: "26'", type: "Substitution", typeId: "76").localizedTitle == "Substitution")
        #expect(SportsKeyEvent(clock: "60'", type: "Penalty - Missed", typeId: "999").localizedTitle == "Penalty missed")
        #expect(SportsKeyEvent(clock: "60'", type: "Own Goal").localizedTitle == "Own goal")
        #expect(SportsKeyEvent(clock: "60'", type: "Something New", typeId: "999").localizedTitle == "Something New")
    }

    @Test func `the yellow card is told apart by id, or by its text for old snapshots`() {
        #expect(SportsKeyEvent(clock: "", type: "Yellow Card", typeId: "94").isYellowCard)
        #expect(SportsKeyEvent(clock: "", type: "Yellow Card").isYellowCard)
        #expect(!SportsKeyEvent(clock: "", type: "Red Card", typeId: "93").isYellowCard)
    }

    @Test func `cricket's live line and result are the provider's summary`() {
        let live = SportsFixtureStatus(state: .inProgress, shortDetail: "Live", clock: "0'", summary: "RR need 40 runs from 20 balls")
        #expect(live.localizedLiveDetail(family: .cricket) == "RR need 40 runs from 20 balls")
        #expect(live.localizedEndingQualifier(family: .cricket) == nil)
        #expect(SportsFixtureStatus(state: .inProgress, shortDetail: "Live").localizedLiveDetail(family: .cricket) == "Live")
        let result = SportsFixtureStatus(state: .final, summary: "Yorkshire won by 185 runs")
        #expect(result.localizedEndingQualifier(family: .cricket) == "Yorkshire won by 185 runs")
        #expect(fixture(leagueId: "espn:cricket/8048").periodFamily == .cricket)
    }

    @Test func `a card with scores hidden drops cricket's state of play but keeps other live lines`() {
        let cricket = SportsFixtureStatus(state: .inProgress, shortDetail: "Live", summary: "Warwickshire lead by 56 runs")
        #expect(cricket.liveDetail(family: .cricket, hidingScores: true) == nil)
        #expect(cricket.liveDetail(family: .cricket, hidingScores: false) == "Warwickshire lead by 56 runs")
        let soccer = status("STATUS_FIRST_HALF", short: "63'", period: 1, clock: "63'")
        #expect(soccer.liveDetail(family: .clockOnly, hidingScores: true) == "63'")
    }

    @Test func `game detail with scores hidden offers only the lineup tab`() {
        let lineup = SportsLineup(teamId: "1", formation: nil, starters: [])
        let full = SportsEventDetail(
            keyEvents: [SportsKeyEvent(clock: "12'", type: "Goal", teamId: "1", isGoal: true)],
            teamStats: [stat("Shots", key: "totalShots")],
            lineups: [lineup]
        )
        #expect(full.availableTabs(hidingScores: false) == [.timeline, .stats, .lineup])
        #expect(full.availableTabs(hidingScores: true) == [.lineup])
        let noLineups = SportsEventDetail(keyEvents: full.keyEvents, teamStats: full.teamStats)
        #expect(noLineups.hasTabContent(hidingScores: false))
        #expect(!noLineups.hasTabContent(hidingScores: true))
    }

    @Test func `tennis names the set in play and how a match ended short`() {
        let live = SportsFixtureStatus(state: .inProgress, shortDetail: "2nd", typeName: "STATUS_IN_PROGRESS", period: 2)
        #expect(live.localizedLiveDetail(family: .sets) == "2nd Set")
        let retired = SportsFixtureStatus(state: .final, typeName: "STATUS_RETIRED", period: 3)
        #expect(retired.phase == .retired)
        #expect(retired.localizedEndingQualifier(family: .sets) == "Retired")
        let walkover = SportsFixtureStatus(state: .final, typeName: "STATUS_WALKOVER")
        #expect(walkover.localizedEndingQualifier(family: .sets) == "Walkover")
        #expect(SportsFixtureStatus(state: .final, typeName: "STATUS_FINAL").localizedEndingQualifier(family: .sets) == nil)
        #expect(fixture(leagueId: "espn:tennis/atp").periodFamily == .sets)
    }

    @Test func `tennis rounds are localised and unknown ones pass through`() {
        #expect(SportsRoundLabel.localized("Quarterfinal") == "Quarterfinal")
        #expect(SportsRoundLabel.localized("Round 3") == "Round 3")
        #expect(SportsRoundLabel.localized("Round Robin") == "Round Robin")
    }

    @Test func `a text score drops its overs parenthetical on cards`() {
        let team = SportsTeam(leagueId: "espn:cricket/8052", teamId: "1", name: "", shortName: "", abbreviation: "")
        #expect(SportsCompetitor(team: team, scoreText: "244 & 335/5 (91 ov, target 334)").displayScore == "244 & 335/5")
        #expect(SportsCompetitor(team: team, scoreText: "212 & 275").displayScore == "212 & 275")
        #expect(SportsCompetitor(team: team, score: 3).displayScore == "3")
        #expect(SportsCompetitor(team: team).displayScore == "0")
    }

    @Test func `stat rows are captioned by key, or by the provider label for an unknown key`() {
        #expect(stat("Corner Kicks", key: "wonCorners").localizedName == "Corner kicks")
        #expect(stat("ON GOAL", key: "shotsOnTarget").localizedName == "Shots on target")
        #expect(stat("Power Play Goals", key: "powerPlayGoals").localizedName == "Power-play goals")
        #expect(stat("Hitouts", key: "hitouts").localizedName == "Hitouts")
        #expect(stat("Possession", key: nil).localizedName == "Possession")
    }
}
