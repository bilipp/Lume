//
//  SportarrLibraryStore.swift
//  Lume
//
//  Plain snapshots for UI and playback. No catalog models, URLs or credentials
//  enter this cache; every launch still resolves the original catalog item.
//

import Foundation
import Observation

@Observable
final class SportarrLibraryStore {
    static let shared = SportarrLibraryStore()
    private(set) var indexes: [UUID: SportarrPlaylistIndex] = [:]
    private(set) var isUnavailable = false
    private(set) var revision = 0
    private(set) var browseHiddenIDs: Set<String> = []

    var files: [SportarrIndexedFile] {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { return [] }
        return indexes.values.flatMap(\.files.values)
    }

    func file(id: String) -> SportarrIndexedFile? {
        files.first { $0.file.catalogID == id }
    }

    func publish(_ index: SportarrPlaylistIndex, unavailable: Bool) {
        indexes[index.playlistID] = index
        isUnavailable = unavailable
        publishPlayback()
    }

    func remove(playlistID: UUID) {
        indexes.removeValue(forKey: playlistID)
        publishPlayback()
    }

    private func publishPlayback() {
        revision += 1
        let records = indexes.values.flatMap(\.files.values)
        SportarrPlaybackRegistry.shared.replace(records)
        browseHiddenIDs = Set(records.filter { $0.file.kind == .movie }.map(\.file.catalogID) + records.compactMap(\.file.seriesID))
    }
}
