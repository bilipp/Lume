//
//  SportsChannelResolver+Cache.swift
//  Lume
//
//  Remembers resolved channels per fixture, so a resolve only does the work for
//  fixtures it hasn't seen under the current catalog, guide and viewer.
//
//  Every Sports surface resolves on its own `.task(id:)` — the Home rail, the
//  hub, a league, a game's detail sheet — and each re-runs whenever its fixture
//  set or the guide's sync state flips. At provider scale a resolve reads the
//  guide rows around every kickoff and 57k channels (seconds of SwiftData row
//  materialization), so the same fixtures were resolved again and again.
//
//  A cached answer is reused only while nothing it depends on has moved: the
//  viewer's category restriction and remembered picks, each playlist's last
//  sync, each guide source's last sync, and the number of hidden channels. The
//  entry also expires after `lifetime`, for what that key can't see (a channel
//  renamed between syncs).
//

import Foundation
import SwiftData
import Synchronization

nonisolated extension SportsChannelResolver {
    /// How far ahead a long list resolves first, so the games at its top get
    /// their channels before the rest of the week is read.
    static let nearTermWindow: TimeInterval = 36 * 3600

    /// The fixtures starting within `nearTermWindow`, when they are only part of
    /// `fixtures` — or nil, when resolving them first would save nothing.
    static func nearTermSubset(of fixtures: [SportsFixture], now: Date) -> [SportsFixture]? {
        let soon = fixtures.filter { $0.startDate < now.addingTimeInterval(nearTermWindow) }
        return soon.isEmpty || soon.count == fixtures.count ? nil : soon
    }

    /// What a resolved answer depends on.
    struct CacheGeneration: Hashable {
        /// The container the answer came from: tests build one per test. The
        /// store file too, since an identifier can be reused once freed.
        let store: ObjectIdentifier
        let storeURL: URL?
        let excludedCategoryIDs: Set<String>
        let picks: [String: String]
        let playlistSyncs: [UUID: Date]
        let guideSyncs: [UUID: Date]
        let hiddenChannels: Int

        /// Read from the store: a few playlist and guide-source rows, and one
        /// indexed count. Not the guide's row total: counting it walks every
        /// page of the largest table on each resolve.
        init(container: ModelContainer, context: ModelContext, restriction: ContentRestriction, picks: [String: String]) {
            store = ObjectIdentifier(container)
            storeURL = container.configurations.first?.url
            excludedCategoryIDs = restriction.excludedCategoryIDs
            self.picks = picks
            let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            playlistSyncs = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0.lastSyncDate ?? .distantPast) })
            let sources = (try? context.fetch(FetchDescriptor<EPGSource>())) ?? []
            guideSyncs = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.lastSyncDate ?? .distantPast) })
            hiddenChannels = (try? context.fetchCount(FetchDescriptor<LiveStream>(predicate: #Predicate { $0.isHidden }))) ?? 0
        }
    }

    /// Resolved channels per fixture, for one `CacheGeneration`.
    ///
    /// Only the answers are kept, which are small. Pass 1's 57k-channel list
    /// would save about 2.7 s on a miss, but it would stay resident between
    /// resolves on the devices where memory is scarcest.
    final class ResolveCache: Sendable {
        static let shared = ResolveCache()

        /// Long enough to cover a session of moving between Sports surfaces;
        /// short enough that a change the generation can't see heals quickly.
        static let lifetime: TimeInterval = 10 * 60

        private let state = Mutex(ResolveCacheState())

        /// A fixture's answer depends on its kickoff as well as its identity.
        static func key(for fixture: SportsFixture) -> String {
            "\(fixture.id)|\(fixture.startDate.timeIntervalSince1970)"
        }

        /// The cached answers for `fixtures` under `generation`, or none when the
        /// generation moved or the entry expired.
        func lookup(
            _ fixtures: [SportsFixture],
            generation: CacheGeneration,
            now: Date = Date()
        ) -> [String: [ResolvedChannel]] {
            state.withLock { state in
                guard state.generation == generation, now.timeIntervalSince(state.createdAt) < Self.lifetime else {
                    state = ResolveCacheState(generation: generation, createdAt: now)
                    return [:]
                }
                var hits: [String: [ResolvedChannel]] = [:]
                for fixture in fixtures {
                    if let cached = state.results[Self.key(for: fixture)] {
                        hits[fixture.id] = cached
                    }
                }
                return hits
            }
        }

        /// Stores freshly resolved answers, if the generation they were built
        /// under is still the current one.
        func store(
            _ results: [String: [ResolvedChannel]],
            for fixtures: [SportsFixture],
            generation: CacheGeneration
        ) {
            state.withLock { state in
                guard state.generation == generation else { return }
                for fixture in fixtures {
                    if let resolved = results[fixture.id] {
                        state.results[Self.key(for: fixture)] = resolved
                    }
                }
            }
        }

        /// Forgets everything; tests use it to start clean.
        func removeAll() {
            state.withLock { $0 = ResolveCacheState() }
        }
    }
}

/// `ResolveCache`'s contents: the answers for one generation.
private nonisolated struct ResolveCacheState {
    var generation: SportsChannelResolver.CacheGeneration?
    var createdAt = Date.distantPast
    var results: [String: [ResolvedChannel]] = [:]
}
