//
//  SportsReplayFilters.swift
//  Lume
//
//  Replay date windows use the device calendar. Last week is Monday to Monday,
//  even in locales whose usual calendar week starts on Sunday.
//

import SwiftUI

nonisolated enum SportsReplayRange: String, CaseIterable, Identifiable {
    case recent, lastWeek, lastSevenDays, season, custom
    var id: Self {
        self
    }

    var title: LocalizedStringKey {
        switch self {
        case .recent: "Recent"
        case .lastWeek: "Last week"
        case .lastSevenDays: "Last 7 days"
        case .season: "This season"
        case .custom: "Choose dates"
        }
    }

    func interval(now: Date, days: Int = 14, calendar: Calendar = .current, custom: ClosedRange<Date>? = nil) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch self {
        case .recent, .lastSevenDays:
            let count = self == .recent ? days : 7
            guard let start = calendar.date(byAdding: .day, value: 1 - count, to: today) else { return nil }
            return DateInterval(start: start, end: tomorrow)
        case .lastWeek:
            let weekday = calendar.component(.weekday, from: today)
            guard let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today),
                  let start = calendar.date(byAdding: .day, value: -7, to: monday) else { return nil }
            return DateInterval(start: start, end: monday)
        case .season: return nil
        case .custom:
            guard let custom,
                  let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: custom.upperBound)) else { return nil }
            return DateInterval(start: calendar.startOfDay(for: custom.lowerBound), end: end)
        }
    }
}

nonisolated extension SportsReplayGame {
    func matches(query: String, aliases: SportsTeamAliases = .bundled, calendar: Calendar = .current) -> Bool {
        let words = SportsMatcher.normalize(query).split(separator: " ")
        guard !words.isEmpty else { return true }
        let weekday = calendar.component(.weekday, from: fixture.startDate)
        let teams = [fixture.home?.team, fixture.away?.team].compactMap(\.self)
        var names = teams.flatMap { [$0.name, $0.shortName, $0.abbreviation] }
        names += aliases.aliases(for: names)
        names += [fixture.leagueName, fixture.leagueAbbreviation, fixture.name, fixture.shortName,
                  fixture.seasonName, fixture.seasonPhase, fixture.weekLabel, fixture.eventHeadline].compactMap(\.self)
        if let week = fixture.week { names.append(String(localized: "Week \(week)")) }
        names += recordings.map(\.title)
        names += fixture.broadcasters
        names.append(calendar.weekdaySymbols[weekday - 1])
        if let sport = SportsCatalog.league(id: fixture.leagueId)?.sport { names.append(sport) }
        let haystack = SportsMatcher.normalize(names.joined(separator: " "))
        return words.allSatisfy { haystack.contains(String($0)) }
    }
}

/// One set of replay filter rules for phone, tablet and television. Metadata
/// levels are optional; a season filter uses each league's latest available
/// season unless the viewer explicitly selects an earlier one.
nonisolated struct SportsReplayFilter {
    var range: SportsReplayRange = .recent
    var recentDays = 14
    var custom: ClosedRange<Date>?
    var myTeams = false
    var followedTeamIDs: Set<String> = []
    var leagueID = ""
    var season: Int?
    var phase = ""
    var week: Int?
    var recentlyAdded = false
    var query = ""

    func apply(_ games: [SportsReplayGame], now: Date = Date(), calendar: Calendar = .current) -> [SportsReplayGame] {
        let interval = range.interval(now: now, days: recentDays, calendar: calendar, custom: custom)
        let latest = games.reduce(into: [String: Int]()) { result, game in
            if let year = game.fixture.seasonYear { result[game.fixture.leagueId] = max(result[game.fixture.leagueId] ?? year, year) }
        }
        return games.filter { game in
            let fixture = game.fixture
            let currentSeason = season ?? latest[fixture.leagueId]
            let mine = [fixture.home?.team.id, fixture.away?.team.id].compactMap(\.self).contains { followedTeamIDs.contains($0) }
            return (interval.map { fixture.startDate >= $0.start && fixture.startDate < $0.end } ?? true)
                && (!myTeams || mine)
                && (leagueID.isEmpty || fixture.leagueId == leagueID)
                && (season == nil || fixture.seasonYear == season)
                && (range != .season || fixture.seasonYear == nil || fixture.seasonYear == currentSeason)
                && (phase.isEmpty || fixture.seasonPhase == phase)
                && (week == nil || fixture.week == week)
                && game.matches(query: query, calendar: calendar)
        }.sorted { recentlyAdded ? $0.addedAt > $1.addedAt : $0.fixture.startDate > $1.fixture.startDate }
    }
}
