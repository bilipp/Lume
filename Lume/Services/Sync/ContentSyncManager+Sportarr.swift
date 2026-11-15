//
//  ContentSyncManager+Sportarr.swift
//  Lume
//
//  Capture existing scan fields without another media-server request. Sibling
//  episodes are classified only after an explicit event or league identifier
//  establishes that their series is Sports. The original catalog stays intact.
//

import Foundation
import SwiftData

extension ContentSyncManager {
    func prepareSportarrScan(playlistID: UUID) async {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { return }
        let index = await SportarrIndexStore.shared.load(playlistID: playlistID)
        sportarrScans[playlistID] = SportarrScan(index: index)
    }

    func captureSportarr(_ item: JellyfinItem, catalogID: String, scope: JellyfinViewScope, seriesID: String? = nil, parent: JellyfinItem? = nil) {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { return }
        guard item.locationType != "Virtual" else {
            sportarrScans[scope.playlistId, default: SportarrScan()].clearedFiles.insert(catalogID)
            return
        }
        let eventID = SportarrIdentifier.eventID(providerIDs: item.providerIds, path: item.path)
        let leagueID = SportarrIdentifier.leagueID(providerIDs: parent?.providerIds)
        let known = seriesID.flatMap { sportarrScans[scope.playlistId]?.series[$0] }
        if eventID != nil, let seriesID { sportarrScans[scope.playlistId, default: SportarrScan()].eventSeries.insert(seriesID) }
        guard eventID != nil || leagueID != nil || known != nil else {
            sportarrScans[scope.playlistId, default: SportarrScan()].clearedFiles.insert(catalogID)
            return
        }
        let reference = seriesID.map {
            SportarrSeriesReference(id: $0, title: parent?.name ?? item.seriesName ?? known?.title ?? "",
                                    leagueID: leagueID ?? known?.leagueID, libraryTitle: scope.view.name)
        }
        guard let file = SportarrImportFile.jellyfin(item, catalogID: catalogID, series: reference, libraryTitle: scope.view.name) else { return }
        sportarrScans[scope.playlistId, default: SportarrScan()].files[catalogID] = file
        if let reference { sportarrScans[scope.playlistId, default: SportarrScan()].series[reference.id] = reference }
    }

    func captureSportarrSeries(_ item: JellyfinItem, catalogID: String, scope: JellyfinViewScope) {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { return }
        sportarrScans[scope.playlistId, default: SportarrScan()].observedSeries.insert(catalogID)
        let league = SportarrIdentifier.leagueID(providerIDs: item.providerIds)
        if league != nil { sportarrScans[scope.playlistId, default: SportarrScan()].explicitSeries.insert(catalogID) }
        guard league != nil || sportarrScans[scope.playlistId]?.series[catalogID] != nil else { return }
        sportarrScans[scope.playlistId, default: SportarrScan()].series[catalogID] = SportarrSeriesReference(
            id: catalogID, title: item.name ?? "", leagueID: league, libraryTitle: scope.view.name
        )
    }

    func finishSportarrScan(playlistID: UUID, sourceType: PlaylistSourceType) async {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { sportarrScans[playlistID] = nil; return }
        var scan = sportarrScans.removeValue(forKey: playlistID) ?? SportarrScan()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        if sourceType == .webdav { captureSportarrWebDAV(playlistID: playlistID, context: context, scan: &scan) }
        let withdrawn = scan.withdrawConfirmedOrdinarySeries()
        for (seriesID, reference) in scan.series {
            let episodes = (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.series?.id == seriesID }))) ?? []
            for episode in episodes where scan.shouldHydrateSibling(id: episode.id) {
                scan.files[episode.id] = SportarrImportFile(
                    catalogID: episode.id, kind: .episode, eventID: nil, title: episode.title,
                    date: SportarrFixtureBridge.fileDate(serverDate: episode.airDate, title: episode.title),
                    seriesID: seriesID, seriesTitle: episode.series?.name, leagueID: reference.leagueID,
                    libraryTitle: reference.libraryTitle, seasonNumber: episode.seasonNum, fileName: SportarrImportFile.fileName(episode.directSource),
                    fingerprint: SportarrImportFile.fingerprint(path: episode.directSource, created: episode.added, duration: episode.durationSecs.map(Int64.init), eventID: nil)
                )
            }
        }
        let missing = staleSportarrIDs(scan.previousFiles, context: context) ?? []
        await SportarrSyncCoordinator.shared.submit(Array(scan.files.values), playlistID: playlistID, series: scan.series,
                                                    removedIDs: scan.clearedFiles.union(missing), removedSeries: withdrawn)
    }

    /// Only proven absence in the local catalog discards derived records.
    /// A failed read cannot stand in for an empty catalog.
    private func staleSportarrIDs(_ records: [String: SportarrIndexedFile], context: ModelContext) -> Set<String>? {
        do {
            var found = Set<String>()
            for kind in [SportarrFileKind.movie, .episode] {
                let ids = records.values.filter { $0.file.kind == kind }.map(\.file.catalogID)
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Set(ids[start ..< min(start + 500, ids.count)])
                    switch kind {
                    case .movie:
                        let rows = try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { chunk.contains($0.id) }))
                        found.formUnion(rows.map(\.id))
                    case .episode:
                        let rows = try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { chunk.contains($0.id) }))
                        found.formUnion(rows.map(\.id))
                    }
                }
            }
            return Set(records.keys).subtracting(found)
        } catch { return nil }
    }

    /// WebDAV's existing import already retained credential-free source URLs.
    /// Read them in bounded pages, including when its unchanged-listing fast
    /// path skipped writes. No second PROPFIND walk is needed.
    private func captureSportarrWebDAV(playlistID: UUID, context: ModelContext, scan: inout SportarrScan) {
        let prefix = playlistID.uuidString
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }, sortBy: [SortDescriptor(\.id)])
            descriptor.fetchLimit = 500
            descriptor.fetchOffset = offset
            let movies = (try? context.fetch(descriptor)) ?? []
            for movie in movies {
                guard let eventID = SportarrIdentifier.eventID(providerIDs: nil, path: movie.directURL) else { continue }
                scan.files[movie.id] = SportarrImportFile(
                    catalogID: movie.id, kind: .movie, eventID: eventID, title: movie.name,
                    date: SportarrFixtureBridge.fileDate(serverDate: movie.releaseDate, title: movie.name),
                    seriesID: nil, seriesTitle: nil, leagueID: nil, libraryTitle: nil, seasonNumber: nil,
                    fileName: SportarrImportFile.fileName(movie.directURL),
                    fingerprint: SportarrImportFile.fingerprint(path: movie.directURL, created: movie.added, duration: nil, eventID: eventID)
                )
            }
            if movies.count < 500 { break }
            offset += movies.count
        }
        offset = 0
        while true {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id.starts(with: prefix) }, sortBy: [SortDescriptor(\.id)])
            descriptor.fetchLimit = 500
            descriptor.fetchOffset = offset
            let episodes = (try? context.fetch(descriptor)) ?? []
            for episode in episodes {
                guard let eventID = SportarrIdentifier.eventID(providerIDs: nil, path: episode.directSource) else { continue }
                scan.files[episode.id] = SportarrImportFile(
                    catalogID: episode.id, kind: .episode, eventID: eventID, title: episode.title,
                    date: SportarrFixtureBridge.fileDate(serverDate: episode.airDate, title: episode.title),
                    seriesID: episode.series?.id, seriesTitle: episode.series?.name, leagueID: nil, libraryTitle: nil, seasonNumber: episode.seasonNum,
                    fileName: SportarrImportFile.fileName(episode.directSource),
                    fingerprint: SportarrImportFile.fingerprint(path: episode.directSource, created: episode.added, duration: episode.durationSecs.map(Int64.init), eventID: eventID)
                )
                if let seriesID = episode.series?.id {
                    scan.series[seriesID] = SportarrSeriesReference(id: seriesID, title: episode.series?.name ?? "", leagueID: nil, libraryTitle: nil)
                }
            }
            if episodes.count < 500 { break }
            offset += episodes.count
        }
    }
}
