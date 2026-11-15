//
//  SportarrSyncCoordinator.swift
//  Lume
//
//  One serial worker for all playlist imports. Cancellation retains the worker
//  handle until it exits, so toggling off/on cannot overlap lookup passes.
//

import Foundation

actor SportarrSyncCoordinator {
    static let shared = SportarrSyncCoordinator()
    private let store: SportarrIndexStore
    private var pending: [UUID: [String: SportarrImportFile]] = [:]
    private var pendingSeries: [UUID: [String: SportarrSeriesReference]] = [:]
    private var pendingRemovedIDs: [UUID: Set<String>] = [:]
    private var pendingRemovedSeries: [UUID: Set<String>] = [:]
    private var worker: Task<Void, Never>?
    private var deleted = Set<UUID>()
    private var historicalFixtures: [String: [SportsFixture]] = [:]

    init(store: SportarrIndexStore = .shared) {
        self.store = store
    }

    func submit(_ files: [SportarrImportFile], playlistID: UUID, series: [String: SportarrSeriesReference] = [:], removedIDs: Set<String> = [], removedSeries: Set<String> = []) {
        guard Self.enabled else { return }
        deleted.remove(playlistID)
        if !removedIDs.isEmpty || !removedSeries.isEmpty {
            pending[playlistID] = pending[playlistID] ?? [:]
            pendingRemovedIDs[playlistID, default: []].formUnion(removedIDs)
            pendingRemovedSeries[playlistID, default: []].formUnion(removedSeries)
        }
        if !series.isEmpty {
            pending[playlistID] = pending[playlistID] ?? [:]
            pendingSeries[playlistID, default: [:]].merge(series, uniquingKeysWith: { _, new in new })
        }
        for file in files {
            pending[playlistID, default: [:]][file.catalogID] = file
        }
        startIfNeeded()
    }

    func settingsChanged() {
        if !Self.enabled {
            pending.removeAll()
            pendingSeries.removeAll()
            pendingRemovedIDs.removeAll()
            pendingRemovedSeries.removeAll()
            worker?.cancel()
        } else { startIfNeeded() }
    }

    func parent(playlistID: UUID, seriesID: String) async -> SportarrSeriesReference? {
        if let parent = pendingSeries[playlistID]?[seriesID] { return parent }
        return await store.load(playlistID: playlistID).sportsSeries[seriesID]
    }

    func restore(playlistIDs: [UUID]) async {
        guard Self.enabled else { return }
        for id in playlistIDs {
            let index = await store.load(playlistID: id)
            await SportarrLibraryStore.shared.publish(index, unavailable: false)
        }
    }

    func remove(playlistID: UUID) async {
        deleted.insert(playlistID)
        pending.removeValue(forKey: playlistID)
        pendingSeries.removeValue(forKey: playlistID)
        pendingRemovedIDs.removeValue(forKey: playlistID)
        pendingRemovedSeries.removeValue(forKey: playlistID)
        try? await store.remove(playlistID: playlistID)
        await SportarrLibraryStore.shared.remove(playlistID: playlistID)
    }

    private func startIfNeeded() {
        guard worker == nil, !pending.isEmpty, Self.enabled else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while Self.enabled, !Task.isCancelled, let id = pending.keys.sorted(by: { $0.uuidString < $1.uuidString }).first {
            let incoming = pending.removeValue(forKey: id) ?? [:]
            var index = await store.load(playlistID: id)
            index.mergeImported(incoming, series: pendingSeries.removeValue(forKey: id) ?? [:],
                                removedIDs: pendingRemovedIDs.removeValue(forKey: id) ?? [],
                                removedSeries: pendingRemovedSeries.removeValue(forKey: id) ?? [])
            // Best-effort records appear even if the public service is down.
            guard !deleted.contains(id), Self.enabled, !Task.isCancelled else { continue }
            try? await store.save(index)
            await SportarrLibraryStore.shared.publish(index, unavailable: false)
            index.historicalFixtures.merge(historicalFixtures, uniquingKeysWith: { old, _ in old })
            let followed = await MainActor.run { SportsFollowService.shared.followedLeagueIds }
            let pass = SportarrResolutionPass(client: SportarrClient(), candidateLeagueIDs: followed)
            let result = await pass.run(index)
            historicalFixtures.merge(result.index.historicalFixtures, uniquingKeysWith: { _, new in new })
            guard !deleted.contains(id), Self.enabled, !Task.isCancelled else { continue }
            try? await store.save(result.index)
            await SportarrLibraryStore.shared.publish(result.index, unavailable: result.unavailable)
        }
        worker = nil
        startIfNeeded()
    }

    private static var enabled: Bool {
        UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey)
    }
}
