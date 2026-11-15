//
//  SportarrMetadata.swift
//  Lume
//
//  Optional fields from the public media-agent routes. A missing field never
//  requires falling back to a private acquisition server or a guessed identity.
//

import Foundation

nonisolated struct SportarrSeries: Codable, Hashable {
    let id: String?
    let title: String?
    let sport: String?
}

nonisolated struct SportarrSeason: Codable {
    let episodes: [SportarrEpisode]?
}

nonisolated struct SportarrEpisode: Codable, Hashable {
    let id: String?
    let title: String?
    let summary: String?
    let homeTeam: String?
    let awayTeam: String?
    let scheduledStart: String?
    let broadcastDate: String?
    let airDate: String?
    let sport: String?
    let seasonNumber: Int?
    let round: String?
    let partName: String?
    let partNumber: Int?
    let venue: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, sport, round, venue
        case homeTeam = "home_team", awayTeam = "away_team"
        case scheduledStart = "scheduled_start_local"
        case broadcastDate = "broadcast_date", airDate = "air_date"
        case seasonNumber = "season_number", partName = "part_name", partNumber = "part_number"
    }

    var kickoff: Date? {
        ESPNClient.parseDate(scheduledStart)
    }

    /// Reject a wrong identifier only when both independent date signals
    /// disagree with the file. Missing metadata is not evidence of a mismatch.
    func agrees(with fileDate: Date?) -> Bool {
        guard let fileDate else { return true }
        let broadcast = Self.day(broadcastDate) ?? Self.day(airDate)
        let scheduled = kickoff
        guard let broadcast, let scheduled else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fileDay = calendar.startOfDay(for: fileDate)
        return [broadcast, scheduled].contains { date in
            let days = calendar.dateComponents([.day], from: fileDay, to: calendar.startOfDay(for: date)).day ?? Int.max
            return abs(days) <= 1
        }
    }

    static func day(_ text: String?) -> Date? {
        guard let text, text.count == 10 else { return nil }
        return ESPNClient.parseDate(text + "T00:00:00Z")
    }
}
