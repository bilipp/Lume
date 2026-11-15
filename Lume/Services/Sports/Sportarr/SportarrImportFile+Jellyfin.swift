//
//  SportarrImportFile+Jellyfin.swift
//  Lume
//
//  Both full and on-demand imports use the same explicit-ID classification.
//  A non-nil series reference has already been established as Sports.
//

import Foundation

nonisolated struct SportarrSeriesReference: Codable, Hashable {
    let id: String
    let title: String
    let leagueID: String?
    let libraryTitle: String?
}

nonisolated extension SportarrImportFile {
    static func jellyfin(_ item: JellyfinItem, catalogID: String, series: SportarrSeriesReference?, libraryTitle: String? = nil) -> Self? {
        let eventID = SportarrIdentifier.eventID(providerIDs: item.providerIds, path: item.path)
        guard eventID != nil || series != nil, item.locationType != "Virtual" else { return nil }
        return Self(
            catalogID: catalogID, kind: series == nil && item.itemType != "Episode" ? .movie : .episode, eventID: eventID,
            title: item.name ?? "", date: SportarrFixtureBridge.fileDate(serverDate: item.premiereDate, title: item.name ?? ""),
            seriesID: series?.id, seriesTitle: series?.title ?? item.seriesName, leagueID: series?.leagueID,
            libraryTitle: libraryTitle ?? series?.libraryTitle, seasonNumber: item.parentIndexNumber,
            fileName: fileName(item.path), fingerprint: fingerprint(path: item.path, created: item.dateCreated, duration: item.runTimeTicks, eventID: eventID)
        )
    }

    static func fileName(_ path: String?) -> String {
        guard let path else { return "" }
        let clean = URLComponents(string: path)?.path ?? path.components(separatedBy: "?")[0]
        return (clean.removingPercentEncoding ?? clean).components(separatedBy: "/").last ?? ""
    }
}
