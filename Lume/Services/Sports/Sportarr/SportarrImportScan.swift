//
//  SportarrImportScan.swift
//  Lume
//
//  A completed walk can withdraw an old classification. A short walk or a
//  server that fetches episodes per show cannot prove that identifiers vanished.
//

import Foundation

nonisolated struct SportarrScan {
    var files: [String: SportarrImportFile] = [:]
    var series: [String: SportarrSeriesReference] = [:]
    var previousFiles: [String: SportarrIndexedFile] = [:]
    var observedSeries = Set<String>()
    var explicitSeries = Set<String>()
    var eventSeries = Set<String>()
    var incompleteSeries = Set<String>()
    var clearedFiles = Set<String>()

    init(index: SportarrPlaylistIndex? = nil) {
        previousFiles = index?.files ?? [:]
        series = index?.sportsSeries ?? [:]
    }

    func shouldHydrateSibling(id: String) -> Bool {
        files[id] == nil && previousFiles[id] == nil
    }

    var withdrawnSeries: Set<String> {
        observedSeries.subtracting(explicitSeries.union(eventSeries).union(incompleteSeries))
    }

    mutating func withdrawConfirmedOrdinarySeries() -> Set<String> {
        let withdrawn = withdrawnSeries
        for id in withdrawn {
            series.removeValue(forKey: id)
        }
        files = files.filter { $0.value.seriesID.map { !withdrawn.contains($0) } ?? true }
        let removed = previousFiles.values.filter { $0.file.seriesID.map(withdrawn.contains) ?? false }.map(\.file.catalogID)
        clearedFiles.formUnion(removed)
        return withdrawn
    }
}
