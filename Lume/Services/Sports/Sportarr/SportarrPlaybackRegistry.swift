//
//  SportarrPlaybackRegistry.swift
//  Lume
//
//  Same lock-guarded snapshot pattern as SportsFollowService: player factories
//  and neighbour resolvers can read a sports identity off the main actor.
//

import Foundation
import os

final nonisolated class SportarrPlaybackRegistry: Sendable {
    static let shared = SportarrPlaybackRegistry()
    private let labels = OSAllocatedUnfairLock(initialState: [String: String]())
    private let hiddenIDs = OSAllocatedUnfairLock(initialState: Set<String>())

    var browseHiddenIDs: Set<String> {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { return [] }
        return hiddenIDs.withLock { $0 }
    }

    func replace(_ records: [SportarrIndexedFile]) {
        let values = Dictionary(records.map { record in
            let fixture = record.fixture
            let title = fixture?.name ?? record.metadata?.title ?? record.file.title
            let label = [title, fixture?.weekLabel].compactMap(\.self).joined(separator: " · ")
            return (record.file.catalogID, label)
        }, uniquingKeysWith: { first, _ in first })
        labels.withLock { $0 = values }
        let movies = records.filter { $0.file.kind == .movie }.map(\.file.catalogID)
        let series = records.compactMap(\.file.seriesID)
        hiddenIDs.withLock { $0 = Set(movies + series) }
    }

    func title(id: String) -> String? {
        guard UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) else { return nil }
        return labels.withLock { $0[id] }
    }

    func isSports(id: String) -> Bool {
        title(id: id) != nil
    }
}
