//
//  SportarrFixtureBridge.swift
//  Lume
//
//  Classification happens before this bridge. Names may locate a fixture, but
//  can never promote an ordinary library file into Sports.
//

import Foundation

nonisolated enum SportarrFixtureBridge {
    static func league(title: String?, sport: String? = nil) -> SportsLeague? {
        guard let title else { return nil }
        let name = SportsMatcher.normalize(title).trimmingCharacters(in: .whitespaces)
        if let id = aliases[name] { return SportsCatalog.league(id: id) }
        let candidates = SportsCatalog.leagues.filter {
            [SportsMatcher.normalize($0.name), SportsMatcher.normalize($0.abbreviation)]
                .contains { $0.trimmingCharacters(in: .whitespaces) == name }
        }
        if candidates.count == 1 { return candidates.first }
        guard let sport else { return nil }
        let sportName = SportsMatcher.normalize(sport)
        let narrowed = candidates.filter { SportsMatcher.normalize($0.sport) == sportName }
        return narrowed.count == 1 ? narrowed.first : nil
    }

    static func fileDate(serverDate: String?, title: String) -> Date? {
        if let date = ESPNClient.parseDate(serverDate) ?? SportarrEpisode.day(serverDate) { return date }
        guard let range = title.range(of: #"\(\d{4}-\d{2}-\d{2}\)\s*$"#, options: .regularExpression) else { return nil }
        return SportarrEpisode.day(String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
    }

    static func teams(in title: String) -> [String]? {
        let stripped = title.replacingOccurrences(of: #"\s*\(\d{4}-\d{2}-\d{2}\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+[^-]+$"#, with: "", options: .regularExpression)
        guard let separator = try? NSRegularExpression(pattern: #"\s+(?:vs\.?|versus|at|@)\s+"#, options: .caseInsensitive) else { return nil }
        let matches = separator.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped))
        guard matches.count == 1, let range = Range(matches[0].range, in: stripped) else { return nil }
        let sides = [String(stripped[..<range.lowerBound]), String(stripped[range.upperBound...])]
        return sides.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ? sides : nil
    }

    /// Each side must name exactly one team across the candidate fixtures. A
    /// shared city or an ambiguous nickname cannot silently join two files.
    static func match(teams: [String], date: Date, precise: Bool, fixtures: [SportsFixture]) -> SportsFixture? {
        guard teams.count == 2 else { return nil }
        let window = fixtures.filter { abs($0.startDate.timeIntervalSince(date)) <= (precise ? 4 * 3600 : 36 * 3600) }
        let allTeams = Dictionary(window.flatMap { [$0.home?.team, $0.away?.team].compactMap(\.self) }
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = teams.map { side -> String? in
            let normalized = SportsMatcher.normalize(side)
            let exact = allTeams.values.filter { team in
                let names = [team.name, team.shortName, team.abbreviation]
                return (names + SportsTeamAliases.bundled.aliases(for: names)).contains { SportsMatcher.normalize($0) == normalized }
            }
            if exact.count == 1 { return exact.first?.id }
            if exact.count > 1 { return nil }
            let hits = allTeams.values.filter { team in
                SportsMatcher.tokens(for: team).contains { normalized.contains(" " + $0 + " ") }
            }
            return hits.count == 1 ? hits.first?.id : nil
        }
        guard let first = resolved[0], let second = resolved[1], first != second else { return nil }
        let candidates = window.filter { fixture in
            let ids = Set([fixture.home?.team.id, fixture.away?.team.id].compactMap(\.self))
            guard ids == Set([first, second]) else { return false }
            let program = EPGProgramCandidate(channelId: "", title: teams.joined(separator: " at "), start: date, end: date.addingTimeInterval(1))
            return SportsMatcher.bestMatch(for: fixture, in: [program], requiresKickoffStart: false) != nil
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static let aliases: [String: String] = {
        guard let url = Bundle.main.url(forResource: "sportarr-league-aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url), let aliases = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return aliases
    }()
}
