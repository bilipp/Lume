//
//  SportarrResolutionPass.swift
//  Lume
//
//  One bounded pass in the sync lifecycle. Season responses resolve a batch;
//  single-event traffic is deduplicated and capped. Sequential requests are
//  deliberately below the two-in-flight ceiling across all playlists.
//

import Foundation

nonisolated protocol SportarrMetadataProvider: Sendable {
    func episode(_ id: String) async -> SportarrLookup<SportarrEpisode>
    func series(_ id: String) async -> SportarrLookup<SportarrSeries>
    func season(leagueID: String, number: Int) async -> SportarrLookup<SportarrSeason>
}

nonisolated struct SportarrResolutionPass {
    let client: any SportarrMetadataProvider
    var now = Date()
    var candidateLeagueIDs: [String] = []
    var isEnabled: @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) }
    var fixtures: @Sendable (SportsLeague, DateComponents) async throws -> [SportsFixture] = { league, month in
        try await ESPNClient().fixtures(league: league, month: month)
    }

    func run(_ input: SportarrPlaylistIndex) async -> (index: SportarrPlaylistIndex, unavailable: Bool) {
        guard isEnabled(), !Task.isCancelled else { return (input, false) }
        var index = input
        var unavailable = await resolveLeagues(in: &index)
        let pending = index.files.values.filter { $0.needsLookup(now: now) }
        var answers = await seasonAnswers(pending, index: &index, unavailable: &unavailable)
        let singles = await eventAnswers(pending, excluding: Set(answers.keys))
        answers.merge(singles, uniquingKeysWith: { first, _ in first })
        for key in index.files.keys.sorted() {
            guard var record = index.files[key] else { continue }
            if let id = record.file.eventID, let answer = answers[id] {
                if case .unavailable = answer { unavailable = true }
                record.apply(answer, now: now)
            }
            index.files[key] = record
        }
        for key in index.files.keys.sorted() {
            guard isEnabled(), !Task.isCancelled, let record = index.files[key], record.fixture == nil else { continue }
            index.files[key] = await matched(record, index: &index)
        }
        guard isEnabled(), !Task.isCancelled else { return (input, unavailable) }
        return (index, unavailable)
    }

    private func resolveLeagues(in index: inout SportarrPlaylistIndex) async -> Bool {
        var unavailable = false
        for id in Set(index.files.values.compactMap(\.file.leagueID)).sorted() where index.leagues[id] == nil {
            guard isEnabled(), !Task.isCancelled else { break }
            switch await client.series(id) {
            case let .found(series): index.leagues[id] = series
            case .unavailable: unavailable = true
            case .missing, .disabled: break
            }
        }
        return unavailable
    }

    private func seasonAnswers(_ pending: [SportarrIndexedFile], index: inout SportarrPlaylistIndex, unavailable: inout Bool) async -> [String: SportarrLookup<SportarrEpisode>] {
        var answers: [String: SportarrLookup<SportarrEpisode>] = [:]
        let groups = Dictionary(grouping: pending.filter { $0.file.leagueID != nil && $0.file.seasonNumber != nil }) {
            $0.file.leagueID! + ":" + String($0.file.seasonNumber!)
        }
        for key in groups.keys.sorted() {
            guard isEnabled(), !Task.isCancelled, let batch = groups[key], Set(batch.compactMap(\.file.eventID)).count >= 3,
                  let file = batch.first?.file, let league = file.leagueID, let season = file.seasonNumber else { continue }
            if index.seasons[key] == nil {
                switch await client.season(leagueID: league, number: season) {
                case let .found(response): index.seasons[key] = response.episodes ?? []
                case .unavailable: unavailable = true
                case .missing, .disabled: break
                }
            }
            let episodes = Dictionary((index.seasons[key] ?? []).compactMap { episode in episode.id.map { ($0.lowercased(), episode) } }, uniquingKeysWith: { first, _ in first })
            for id in batch.compactMap(\.file.eventID) {
                if let episode = episodes[id] { answers[id] = .found(episode) }
            }
        }
        return answers
    }

    private func eventAnswers(_ pending: [SportarrIndexedFile], excluding: Set<String>) async -> [String: SportarrLookup<SportarrEpisode>] {
        var answers: [String: SportarrLookup<SportarrEpisode>] = [:]
        for id in Set(pending.compactMap(\.file.eventID)).subtracting(excluding).sorted().prefix(25) {
            guard isEnabled(), !Task.isCancelled else { break }
            answers[id] = await client.episode(id)
        }
        return answers
    }

    private func matched(_ input: SportarrIndexedFile, index: inout SportarrPlaylistIndex) async -> SportarrIndexedFile {
        var record = input
        let series = record.file.leagueID.flatMap { index.leagues[$0] }
        let direct = SportarrFixtureBridge.league(title: series?.title ?? record.file.seriesTitle, sport: series?.sport)
        record.espnLeagueID = direct?.id
        guard let date = record.metadata?.kickoff ?? record.file.date else { return record }
        let teams: [String]? = if let home = record.metadata?.homeTeam, let away = record.metadata?.awayTeam {
            [home, away]
        } else {
            SportarrFixtureBridge.teams(in: record.file.title)
        }
        guard let teams else { return record }
        let candidates = direct.map { [$0] } ?? movieLeagues(for: record.file, in: index)
        var matches: [SportsFixture] = []
        for league in candidates {
            let precise = record.metadata?.kickoff != nil
            let fixtures = await historicalFixtures(league: league, date: date, precise: precise, index: &index)
            if let fixture = SportarrFixtureBridge.match(teams: teams, date: date, precise: precise, fixtures: fixtures) { matches.append(fixture) }
        }
        if matches.count == 1 {
            record.fixture = matches.first
            record.espnLeagueID = matches.first?.leagueId
            record.matchedFromTitle = record.metadata == nil
        }
        return record
    }

    private func historicalFixtures(league: SportsLeague, date: Date, precise: Bool, index: inout SportarrPlaylistIndex) async -> [SportsFixture] {
        let span: TimeInterval = precise ? 4 * 3600 : 36 * 3600
        var months = Set<String>()
        var available: [SportsFixture] = []
        for day in [date.addingTimeInterval(-span), date, date.addingTimeInterval(span)] {
            let month = Self.calendar.dateComponents([.year, .month], from: day)
            let key = league.id + ":" + String(month.year ?? 0) + ":" + String(month.month ?? 0)
            guard months.insert(key).inserted else { continue }
            if index.historicalFixtures[key] == nil, isEnabled(), !Task.isCancelled {
                if let fetched = try? await fixtures(league, month) { index.historicalFixtures[key] = fetched }
            }
            available += index.historicalFixtures[key] ?? []
        }
        return Array(Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }

    private func movieLeagues(for file: SportarrImportFile, in index: SportarrPlaylistIndex) -> [SportsLeague] {
        guard file.kind == .movie else { return [] }
        var ids = Set(candidateLeagueIDs)
        if let library = file.libraryTitle {
            for other in index.files.values where other.file.libraryTitle == library {
                let series = other.file.leagueID.flatMap { index.leagues[$0] }
                if let league = SportarrFixtureBridge.league(title: series?.title ?? other.file.seriesTitle, sport: series?.sport) { ids.insert(league.id) }
            }
        }
        return ids.sorted().compactMap { SportsCatalog.league(id: $0) }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
