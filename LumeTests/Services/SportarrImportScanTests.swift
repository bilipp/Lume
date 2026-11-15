//
//  SportarrImportScanTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct SportarrImportScanTests {
    private func index() -> SportarrPlaylistIndex {
        var index = SportarrPlaylistIndex(playlistID: UUID())
        index.sportsSeries["series"] = SportarrSeriesReference(id: "series", title: "NFL", leagueID: nil, libraryTitle: "Sports")
        let file = SportarrImportFile(catalogID: "episode", kind: .episode, eventID: "ev-123456", title: "Game", date: nil,
                                      seriesID: "series", seriesTitle: "NFL", leagueID: nil, libraryTitle: "Sports", seasonNumber: 2026, fileName: "game", fingerprint: "original")
        index.files[file.catalogID] = SportarrIndexedFile(file: file)
        return index
    }

    @Test func `a partial or per show walk cannot withdraw a cached sports identity`() {
        let original = index()
        var scan = SportarrScan(index: original)
        scan.observedSeries = ["series"]
        scan.incompleteSeries = ["series"]
        #expect(scan.withdrawConfirmedOrdinarySeries().isEmpty)
        #expect(!scan.shouldHydrateSibling(id: "episode"))
        #expect(scan.previousFiles["episode"]?.file.eventID == "ev-123456")
        #expect(scan.previousFiles["episode"]?.file.fingerprint == "original")
        var updated = original
        updated.mergeImported(scan.files, series: scan.series, removedIDs: scan.clearedFiles, removedSeries: scan.withdrawnSeries)
        #expect(updated.files["episode"]?.file.eventID == "ev-123456")
    }

    @Test func `a complete walk with all identifiers withdrawn restores ordinary browsing`() {
        var original = index()
        var scan = SportarrScan(index: original)
        scan.observedSeries = ["series"]
        let removedSeries = scan.withdrawConfirmedOrdinarySeries()
        #expect(removedSeries == ["series"])
        #expect(scan.clearedFiles == ["episode"])
        original.mergeImported(scan.files, series: scan.series, removedIDs: scan.clearedFiles, removedSeries: removedSeries)
        #expect(original.files.isEmpty)
        #expect(original.sportsSeries.isEmpty)
    }

    @Test(arguments: [true, false]) func `an explicit parent or one identified sibling retains the series`(parentHasLeague: Bool) {
        var scan = SportarrScan(index: index())
        scan.observedSeries = ["series"]
        if parentHasLeague {
            scan.explicitSeries = ["series"]
        } else {
            scan.eventSeries = ["series"]
        }
        #expect(scan.withdrawConfirmedOrdinarySeries().isEmpty)
        #expect(scan.series["series"] != nil)
        #expect(scan.shouldHydrateSibling(id: "new-sibling"))
    }

    @Test func `only confirmed missing catalog identities leave the derived cache`() {
        var original = index()
        let retained = original.files["episode"]
        original.mergeImported([:], series: [:], removedIDs: ["another-file"], removedSeries: [])
        #expect(original.files["episode"] == retained)
        original.mergeImported([:], series: [:], removedIDs: ["episode"], removedSeries: [])
        #expect(original.files.isEmpty)
    }
}
