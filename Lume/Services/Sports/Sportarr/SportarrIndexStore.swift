//
//  SportarrIndexStore.swift
//  Lume
//
//  One private JSON index per playlist beside the existing Sports cache. The
//  actor owns disk access, so no catalog models or saves cross onto MainActor.
//

import Foundation

actor SportarrIndexStore {
    static let shared = SportarrIndexStore()
    private let directory: URL

    init(directory: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appending(path: "Sports/Sportarr", directoryHint: .isDirectory)
    }

    func load(playlistID: UUID) -> SportarrPlaylistIndex {
        guard let data = try? Data(contentsOf: fileURL(playlistID)),
              let index = try? JSONDecoder().decode(SportarrPlaylistIndex.self, from: data),
              index.version == SportarrPlaylistIndex.schemaVersion, index.playlistID == playlistID
        else {
            return SportarrPlaylistIndex(playlistID: playlistID)
        }
        return index
    }

    func save(_ index: SportarrPlaylistIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(index)
        let url = fileURL(index.playlistID)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(playlistID: UUID) throws {
        let url = fileURL(playlistID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(_ playlistID: UUID) -> URL {
        directory.appendingPathComponent(playlistID.uuidString.lowercased()).appendingPathExtension("json")
    }
}
