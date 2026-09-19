//
//  SportsCacheStore.swift
//  Lume
//
//  On-disk cache for the Sports Hub. Each followed league gets ONE Codable JSON
//  snapshot (`SportsLeagueSnapshot`) written to `Caches/Sports/`, replaced
//  wholesale on every refresh — there is deliberately no SwiftData `@Model` for
//  sports data (see the Sports Hub design decisions). It is derived, re-fetchable
//  cache, so it lives in the caches directory like `ImageDiskCache`, not in the
//  catalog store.
//
//  A `nonisolated struct` so the background refresh (a `nonisolated` provider on a
//  utility Task) can read and write it without hopping to the main actor.
//

import Foundation
import OSLog

/// The full cached state for one league: its fixtures, standings and teams, plus
/// when the snapshot (and, separately, its rarely-changing team roster) was
/// fetched. `teamsFetchedAt` lets the refresh reuse the crest/colour roster for a
/// week instead of re-downloading `/teams` on every pass.
nonisolated struct SportsLeagueSnapshot: Codable, Hashable {
    var fetchedAt: Date
    var fixtures: [SportsFixture]
    var standings: [SportsStandingRow]
    var teams: [SportsTeam]
    /// When `teams` was last downloaded; `nil` for a snapshot written before this
    /// field existed, which the refresh treats as "due for a team refresh".
    var teamsFetchedAt: Date?

    init(
        fetchedAt: Date = Date(),
        fixtures: [SportsFixture] = [],
        standings: [SportsStandingRow] = [],
        teams: [SportsTeam] = [],
        teamsFetchedAt: Date? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.fixtures = fixtures
        self.standings = standings
        self.teams = teams
        self.teamsFetchedAt = teamsFetchedAt
    }
}

nonisolated struct SportsCacheStore {
    private let directory: URL
    private let fileManager = FileManager.default

    /// - Parameter directory: overridable for tests; defaults to `Caches/Sports/`.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Sports", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func load(leagueId: String) -> SportsLeagueSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: leagueId)) else { return nil }
        do {
            return try JSONDecoder().decode(SportsLeagueSnapshot.self, from: data)
        } catch {
            let message = error.localizedDescription
            Logger.sync.warning("Sports cache: decode failed for \(leagueId, privacy: .public): \(message, privacy: .public)")
            return nil
        }
    }

    func save(_ snapshot: SportsLeagueSnapshot, for leagueId: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL(for: leagueId), options: .atomic)
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A league id ("espn:soccer/ger.1") carries `:` and `/`, neither safe in a
    /// path component, so they collapse to `_`. The catalogue's slugs are unique
    /// once folded this way, so the mapping needs no hashing.
    private func fileURL(for leagueId: String) -> URL {
        let safe = leagueId
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }
}
