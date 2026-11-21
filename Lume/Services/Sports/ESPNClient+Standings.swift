//
//  ESPNClient+Standings.swift
//  Lume
//
//  Standings mapping, separated from scoreboard and event-detail mapping.
//

import Foundation

nonisolated extension ESPNClient {
    // MARK: Standings

    /// Walks every group (conferences, F1's driver/constructor tables) plus a
    /// single-table league's root entries (AFL, NBL). A group that names no kind
    /// is read from its rows: athlete entries are drivers (NASCAR, IndyCar).
    static func mapStandings(_ response: ESPNStandingsResponse) -> [SportsStandingRow] {
        var groups: [(name: String?, entries: [ESPNStandingsEntry])] = (response.children ?? []).map {
            ($0.name, $0.standings?.entries ?? [])
        }
        if let rootEntries = response.standings?.entries, !rootEntries.isEmpty {
            groups.append((nil, rootEntries))
        }

        var rows: [SportsStandingRow] = []
        for group in groups {
            let kind = standingKind(childName: group.name)
            let groupName = groups.count > 1 ? group.name : nil
            for (index, entry) in group.entries.enumerated() {
                let resolvedKind = kind == .team && entry.team == nil && entry.athlete != nil ? .driver : kind
                if let row = mapStandingEntry(entry, kind: resolvedKind, fallbackRank: index + 1, group: groupName) {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    private static func standingKind(childName: String?) -> SportsStandingKind {
        guard let name = childName?.lowercased() else { return .team }
        if name.contains("constructor") { return .constructor }
        if name.contains("driver") { return .driver }
        return .team
    }

    /// Indexes an entry's stats by name and abbreviation and resolves the few
    /// numeric fields the standings rows need.
    private struct StandingStatLookup {
        private let byName: [String: ESPNStat]
        private let byAbbreviation: [String: ESPNStat]
        let extra: [String: String]

        init(entry: ESPNStandingsEntry) {
            var byName: [String: ESPNStat] = [:]
            var byAbbreviation: [String: ESPNStat] = [:]
            var extra: [String: String] = [:]
            for stat in entry.stats ?? [] {
                if let name = stat.name { byName[name] = stat }
                if let abbreviation = stat.abbreviation { byAbbreviation[abbreviation] = stat }
                if let key = stat.name ?? stat.abbreviation, let display = stat.displayValue {
                    extra[key] = display
                }
            }
            self.byName = byName
            self.byAbbreviation = byAbbreviation
            self.extra = extra
        }

        func intStat(_ name: String) -> Int? {
            guard let stat = byName[name] else { return nil }
            if let value = stat.value { return Int(value) }
            return stat.displayValue.flatMap { Int($0) }
        }

        /// The first of several provider spellings for one figure — rugby and
        /// the NRL say `gamesWon`/`gamesLost`/`gamesDrawn`/`pointsDifference`,
        /// cricket `matchesPlayed`/`matchesWon`/`matchesLost`/`matchPoints`,
        /// where every other sport says `wins`/`losses`/`ties`/`pointDifferential`.
        func intStat(anyOf names: [String]) -> Int? {
            for name in names {
                if let value = intStat(name) { return value }
            }
            return nil
        }

        func rankStat() -> Int? {
            if let rank = intStat("rank") { return rank }
            if let stat = byAbbreviation["RK"], let value = stat.value ?? stat.displayValue.flatMap({ Double($0) }) {
                return Int(value)
            }
            return nil
        }

        func pointsStat() -> Int? {
            if let points = intStat(anyOf: ["points", "championshipPts", "matchPoints"]) { return points }
            if let stat = byAbbreviation["PTS"], let value = stat.value ?? stat.displayValue.flatMap({ Double($0) }) {
                return Int(value)
            }
            return nil
        }
    }

    private static func mapStandingEntry(
        _ entry: ESPNStandingsEntry,
        kind: SportsStandingKind,
        fallbackRank: Int,
        group: String?
    ) -> SportsStandingRow? {
        let stats = StandingStatLookup(entry: entry)

        switch kind {
        case .team:
            guard let team = entry.team, let teamId = team.id else { return nil }
            return SportsStandingRow(
                id: teamId,
                kind: .team,
                teamId: teamId,
                name: team.displayName ?? team.shortDisplayName ?? teamId,
                rank: stats.rankStat() ?? fallbackRank,
                played: stats.intStat(anyOf: ["gamesPlayed", "matchesPlayed"]),
                wins: stats.intStat(anyOf: ["wins", "gamesWon", "matchesWon"]),
                draws: stats.intStat(anyOf: ["ties", "gamesDrawn", "matchesDrawn"]),
                losses: stats.intStat(anyOf: ["losses", "gamesLost", "matchesLost"]),
                goalDifference: stats.intStat(anyOf: ["pointDifferential", "pointsDifference"]),
                points: stats.pointsStat(),
                extra: stats.extra,
                group: group
            )
        case .driver:
            guard let athlete = entry.athlete else { return nil }
            let id = athlete.id ?? athlete.displayName ?? UUID().uuidString
            return SportsStandingRow(
                id: id,
                kind: .driver,
                teamId: nil,
                name: athlete.displayName ?? id,
                rank: stats.rankStat() ?? fallbackRank,
                points: stats.pointsStat(),
                extra: stats.extra,
                group: group
            )
        case .player:
            return nil
        case .constructor:
            let id = entry.team?.id ?? entry.team?.displayName ?? UUID().uuidString
            return SportsStandingRow(
                id: id,
                kind: .constructor,
                teamId: entry.team?.id,
                name: entry.team?.displayName ?? entry.team?.shortDisplayName ?? id,
                rank: stats.rankStat() ?? fallbackRank,
                points: stats.pointsStat(),
                extra: stats.extra,
                group: group
            )
        }
    }
}
