//
//  SportarrLibraryCatalog.swift
//  Lume
//
//  Join disposable metadata back to the original catalog under the active
//  profile. Missing and restricted files never appear or acquire playback URLs.
//

import Foundation
import SwiftData

nonisolated struct SportsLibraryVersion: Identifiable, Hashable {
    let playlistID: UUID
    let catalogID: String
    let kind: SportarrFileKind
    let label: String
    let title: String
    let addedAt: Date
    let matchedFromTitle: Bool
    var id: String {
        playlistID.uuidString + ":" + catalogID
    }
}

nonisolated enum SportsReplayVersion: Identifiable, Hashable {
    case recording(ServerRecording)
    case library(SportsLibraryVersion)

    var id: String {
        switch self {
        case let .recording(recording): "recording:" + recording.id.rawValue
        case let .library(file): "library:" + file.id
        }
    }

    var label: String {
        switch self {
        case let .recording(recording): String(localized: "Recording") + " · " + (recording.channelName ?? recording.title)
        case let .library(file): file.label
        }
    }

    func progress(namespace: String?, in context: ModelContext) -> Double {
        switch self {
        case let .recording(recording): return RecordingProgressStore.resumePosition(for: recording, namespace: namespace)
        case let .library(file):
            let id = file.catalogID
            switch file.kind {
            case .movie: return (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first?.watchProgress) ?? 0
            case .episode: return (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })).first?.watchProgress) ?? 0
            }
        }
    }
}

nonisolated enum SportarrLibraryCatalog {
    @concurrent
    static func games(indexes: [SportarrPlaylistIndex], scope: CatalogScope, restriction: ContentRestriction, container: ModelContainer) async -> [SportsReplayGame] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var games: [SportsReplayGame] = []
        for index in indexes where scope.playlistIDs.contains(index.playlistID) {
            for record in index.files.values {
                guard exists(record.file, restriction: restriction, context: context) else { continue }
                let fixture = record.fixture ?? fallback(record, index: index)
                let label = record.metadata?.partName ?? (record.file.fileName.isEmpty ? record.file.title : record.file.fileName)
                let version = SportsLibraryVersion(playlistID: index.playlistID, catalogID: record.file.catalogID, kind: record.file.kind,
                                                   label: label, title: record.file.title, addedAt: record.file.date ?? fixture.startDate, matchedFromTitle: record.matchedFromTitle)
                games.append(SportsReplayGame(fixture: fixture, recordings: [], libraryFiles: [version]))
            }
        }
        return merge(games)
    }

    static func merge(_ games: [SportsReplayGame]) -> [SportsReplayGame] {
        Dictionary(grouping: games, by: \.id).values.compactMap { versions in
            guard let first = versions.first else { return nil }
            let recordings = Dictionary(versions.flatMap(\.recordings).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.createdAt > $1.createdAt }
            let files = Dictionary(versions.flatMap(\.libraryFiles).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
            return SportsReplayGame(fixture: first.fixture, recordings: recordings, libraryFiles: files)
        }.sorted { $0.fixture.startDate > $1.fixture.startDate }
    }

    private static func exists(_ file: SportarrImportFile, restriction: ContentRestriction, context: ModelContext) -> Bool {
        let id = file.catalogID
        switch file.kind {
        case .movie:
            guard let movie = try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first else { return false }
            return !restriction.hides(categoryID: movie.categoryId)
        case .episode:
            guard let episode = try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })).first else { return false }
            return !restriction.hides(categoryID: episode.series?.categoryId)
        }
    }

    private static func fallback(_ record: SportarrIndexedFile, index: SportarrPlaylistIndex) -> SportsFixture {
        let series = record.file.leagueID.flatMap { index.leagues[$0] }
        let league = record.espnLeagueID.flatMap { SportsCatalog.league(id: $0) }
            ?? SportarrFixtureBridge.league(title: series?.title ?? record.file.seriesTitle, sport: series?.sport)
        let leagueID = league?.id ?? record.file.leagueID.map { "sportarr:" + $0 } ?? "sportarr:uncategorized"
        // Explicit event identity can group editions. An unresolvable title
        // always keeps its catalog identity, even if another title is identical.
        let id = record.file.eventID.map { "sportarr:" + $0 } ?? "catalog:" + record.file.catalogID
        let title = record.metadata?.title ?? record.file.title
        let date = record.metadata?.kickoff ?? record.file.date ?? SportarrEpisode.day(record.metadata?.broadcastDate) ?? .distantPast
        let leagueTitle = league?.name ?? (record.file.leagueID != nil ? series?.title ?? record.file.seriesTitle : nil)
        return SportsFixture(id: id, leagueId: leagueID, leagueName: leagueTitle ?? String(localized: "Uncategorized"),
                             leagueAbbreviation: league?.abbreviation ?? series?.title ?? "", startDate: date,
                             status: SportsFixtureStatus(state: .final), venue: record.metadata?.venue, name: title,
                             round: record.metadata?.round, seasonYear: record.metadata?.seasonNumber ?? record.file.seasonNumber)
    }
}
