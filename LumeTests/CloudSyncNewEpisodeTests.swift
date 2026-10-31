//
//  CloudSyncNewEpisodeTests.swift
//  LumeTests
//
//  Xtream, Stalker and per-show media servers list a series' episodes only
//  when it opens, so the synced watch state for them waits in the mirror. The
//  engine applies it the moment `Series.insertEpisodes` creates the rows, not
//  at the next reconcile, and a re-created row takes its state back instead of
//  reading as the user clearing it.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudSyncNewEpisodeTests {
    private let watchedAt = Date(timeIntervalSince1970: 1_793_000_000)

    private func freshShadow() -> CloudSyncShadow {
        let suite = UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!
        return CloudSyncShadow(defaults: suite)
    }

    /// A playlist with one series whose episodes haven't been listed yet.
    private func makeCatalog(in context: ModelContext) throws -> (series: Series, episodeIDs: [String]) {
        let playlist = Playlist(name: "Harbor TV", serverURL: "http://x", username: "u", password: "p")
        context.insert(playlist)
        let seriesID = "\(playlist.id.uuidString)-series-700"
        let series = Series(id: seriesID, seriesId: 700, name: "Tidewater")
        context.insert(series)
        try context.save()
        return (series, (1 ... 3).map { "\(seriesID)-episode-\(7000 + $0)" })
    }

    private func parsed(_ id: String, number: Int) -> ParsedEpisode {
        ParsedEpisode(
            id: id, episodeId: String(number), title: "Episode \(number)", containerExtension: "mkv",
            seasonNum: 1, episodeNum: number, added: nil, directSource: nil, durationSecs: 2400,
            movieImage: nil, rating: nil, airDate: nil, plot: nil
        )
    }

    private func watchedMirror(_ id: String) -> UserContentState {
        UserContentState(
            contentId: id, kind: .episode, profileID: UserProfile.defaultProfileID,
            watchProgress: 2400, isWatched: true, lastWatchedDate: watchedAt
        )
    }

    private func episode(_ id: String, in context: ModelContext) throws -> Episode? {
        try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func `synced state applies to episodes a series just listed`() async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let (series, ids) = try makeCatalog(in: context)
        // Another device watched the first two.
        context.insert(watchedMirror(ids[0]))
        context.insert(watchedMirror(ids[1]))
        try context.save()
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        let first = await engine.reconcile()
        #expect(first.contentPending == 2)

        series.insertEpisodes(ids.enumerated().map { parsed($1, number: $0 + 1) }, into: context)
        let applied = await engine.applyCloudState(toNewEpisodes: ids)

        #expect(applied == 2)
        #expect(try episode(ids[0], in: context)?.isWatched == true)
        #expect(try episode(ids[1], in: context)?.watchProgress == 2400)
        #expect(try episode(ids[1], in: context)?.lastWatchedDate == watchedAt)
        #expect(try episode(ids[2], in: context)?.isWatched == false)
        // The baseline matches both sides: the next pass moves nothing.
        let next = await engine.reconcile()
        #expect(next.contentPulled == 0)
        #expect(next.contentPushed == 0)
        #expect(next.contentPending == 0)
    }

    @Test func `a re-created episode takes its synced state instead of deleting it`() async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let (series, ids) = try makeCatalog(in: context)
        series.insertEpisodes([parsed(ids[0], number: 1)], into: context)
        try #require(try episode(ids[0], in: context)).setWatched(true)
        try context.save()
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()
        #expect(try context.fetch(FetchDescriptor<UserContentState>()).count == 1)

        // A sync drops and re-lists the series before the next pass: the row
        // comes back with no state while the baseline still says watched.
        for listed in series.episodes {
            context.delete(listed)
        }
        context.delete(series)
        try context.save()
        let relisted = Series(id: series.id, seriesId: 700, name: "Tidewater")
        context.insert(relisted)
        try context.save()
        relisted.insertEpisodes([parsed(ids[0], number: 1)], into: context)
        #expect(await engine.applyCloudState(toNewEpisodes: [ids[0]]) == 1)
        _ = await engine.reconcile()

        #expect(try episode(ids[0], in: context)?.isWatched == true)
        let mirrors = try context.fetch(FetchDescriptor<UserContentState>())
        #expect(mirrors.count == 1)
        #expect(mirrors.first?.isWatched == true)
    }

    @Test func `an episode played since it was listed keeps its own progress`() async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let (series, ids) = try makeCatalog(in: context)
        context.insert(watchedMirror(ids[0]))
        try context.save()
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())

        series.insertEpisodes([parsed(ids[0], number: 1)], into: context)
        try #require(try episode(ids[0], in: context)).watchProgress = 90
        try context.save()

        #expect(await engine.applyCloudState(toNewEpisodes: [ids[0]]) == 0)
        #expect(try episode(ids[0], in: context)?.watchProgress == 90)
    }

    @Test func `another profile's state stays off the new episodes`() async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let (series, ids) = try makeCatalog(in: context)
        let mirror = watchedMirror(ids[0])
        mirror.profileID = UUID()
        context.insert(mirror)
        try context.save()
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())

        series.insertEpisodes([parsed(ids[0], number: 1)], into: context)

        #expect(await engine.applyCloudState(toNewEpisodes: [ids[0]]) == 0)
        #expect(try episode(ids[0], in: context)?.isWatched == false)
    }

    @Test func `listing episodes announces only the ones it created`() throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let (series, ids) = try makeCatalog(in: context)
        series.insertEpisodes([parsed(ids[0], number: 1)], into: context)
        let announced = Announcements()
        // `queue: nil`: delivered synchronously on the posting (main) thread.
        let observer = NotificationCenter.default.addObserver(
            forName: .lumeEpisodesDidMaterialize, object: nil, queue: nil
        ) { notification in
            announced.ids.append(notification.userInfo?[Notification.episodeIDsKey] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        series.insertEpisodes(ids.enumerated().map { parsed($1, number: $0 + 1) }, into: context)
        series.insertEpisodes([parsed(ids[0], number: 1)], into: context)

        #expect(announced.ids == [Array(ids.dropFirst())])
    }
}

/// What the test observer heard. Posts arrive synchronously on the main thread.
private final nonisolated class Announcements: @unchecked Sendable {
    var ids: [[String]] = []
}
