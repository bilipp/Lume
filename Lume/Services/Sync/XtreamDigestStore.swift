//
//  XtreamDigestStore.swift
//  Lume
//
//  Where the Xtream sync remembers the fingerprint of each bulk endpoint's
//  response it last imported, so an unchanged re-download can skip the decode,
//  the upsert and the sweep.
//
//  Device-local for the same reason as `M3UDigestStore`: the digest records
//  what *this* device has written into *its* store. Each entry also carries the
//  row count the import left behind, so a store that lost its rows (recreated,
//  or wiped by a migration failure) is never mistaken for an imported one.
//  `PlaylistDeletion` clears the keys.
//

import Foundation

nonisolated enum XtreamDigestStore {
    /// One bulk catalog endpoint, named by the row kind it fills.
    enum Endpoint: String, CaseIterable {
        case movies
        case series
        case live
    }

    struct Entry: Equatable {
        let digest: String
        let rowCount: Int
    }

    static func key(playlistId: UUID, endpoint: Endpoint) -> String {
        "sync.xtreamDigest.\(playlistId.uuidString).\(endpoint.rawValue)"
    }

    static func entry(playlistId: UUID, endpoint: Endpoint) -> Entry? {
        guard let stored = UserDefaults.standard.string(forKey: key(playlistId: playlistId, endpoint: endpoint)),
              let separator = stored.firstIndex(of: ":"),
              let rowCount = Int(stored[..<separator])
        else { return nil }
        return Entry(digest: String(stored[stored.index(after: separator)...]), rowCount: rowCount)
    }

    static func store(_ entry: Entry, playlistId: UUID, endpoint: Endpoint) {
        UserDefaults.standard.set("\(entry.rowCount):\(entry.digest)", forKey: key(playlistId: playlistId, endpoint: endpoint))
    }

    static func remove(playlistId: UUID, endpoint: Endpoint) {
        UserDefaults.standard.removeObject(forKey: key(playlistId: playlistId, endpoint: endpoint))
    }

    static func removeAll(playlistId: UUID) {
        for endpoint in Endpoint.allCases {
            remove(playlistId: playlistId, endpoint: endpoint)
        }
    }
}
