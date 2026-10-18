//
//  CastProgressCommitTests.swift
//  LumeTests
//
//  A cast the viewer left playing after closing the player still gets its
//  watch progress written when the receiver stops — by `CastService`, since no
//  player is there to do it — and never twice when a player is.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CastProgressCommitTests {
    @MainActor
    private final class Harness {
        let provider: StubCastProvider
        let service: CastService
        let container: ModelContainer
        let committer: CastProgressCommitter
        let trackers: TrackerRecorder
        let movieID: String
        let channelID: String

        init() throws {
            let container = try makeTestContainer()
            let movieID = "cast-movie-\(UUID().uuidString)"
            let channelID = "cast-live-\(UUID().uuidString)"
            let context = ModelContext(container)
            context.insert(Movie(id: movieID, streamId: 1, name: "Film"))
            context.insert(LiveStream(id: channelID, streamId: 2, name: "Channel"))
            try context.save()
            let trackers = TrackerRecorder()
            let provider = StubCastProvider()
            self.container = container
            self.movieID = movieID
            self.channelID = channelID
            self.trackers = trackers
            self.provider = provider
            service = CastService(castProvider: provider)
            committer = CastProgressCommitter(
                container: container,
                syncWatched: { trackers.synced.append($0) },
                noteCompletedTitle: { trackers.completedTitles += 1 }
            )
            service.progressCommitter = committer
            provider.simulateConnection(.connected)
        }

        var synced: [PlayableMedia.ContentRef] {
            trackers.synced
        }

        var completedTitles: Int {
            trackers.completedTitles
        }

        var movieRef: PlayableMedia.ContentRef {
            .movie(movieID)
        }

        func request(live: Bool = false, ref: PlayableMedia.ContentRef? = nil) -> CastMediaRequest {
            CastMediaRequest(
                contentURL: URL(string: live ? "https://example.com/live/7.m3u8" : "https://example.com/movie/1.mp4")
                    ?? URL(fileURLWithPath: "/"),
                contentType: live ? "application/x-mpegURL" : "video/mp4",
                streamType: live ? .live : .buffered,
                title: "Title",
                subtitle: nil,
                posterURL: nil,
                startTime: 0,
                contentRef: ref ?? (live ? .live(channelID) : movieRef)
            )
        }

        func media(for request: CastMediaRequest) -> PlayableMedia {
            PlayableMedia(
                id: "item-\(request.contentRef)",
                url: request.contentURL,
                title: request.title,
                subtitle: nil,
                posterURL: nil,
                kind: request.streamType == .live ? .live : .vod,
                startTime: 0,
                contentRef: request.contentRef,
                httpHeaders: nil
            )
        }

        func makeSession() -> PlayerCastSession {
            PlayerCastSession(
                clock: PlaybackClock(), castService: service,
                transportTarget: NoTransport(), setHold: { _ in }
            )
        }

        func settle() async {
            await committer.pendingCommit?.value
        }

        func movie() throws -> Movie? {
            let id = movieID
            return try ModelContext(container).fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first
        }

        func channelLastWatched() throws -> Date? {
            let id = channelID
            let descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
            return try ModelContext(container).fetch(descriptor).first?.lastWatchedDate
        }
    }

    @MainActor
    private final class TrackerRecorder {
        var synced: [PlayableMedia.ContentRef] = []
        var completedTitles = 0
    }

    @MainActor
    private final class NoTransport: CastTransportTarget {
        func attachTransport(_: NowPlayingService.Transport, owner _: AnyObject) {}
        func detachTransport(owner _: AnyObject) {}
    }

    // MARK: - Policy

    @Test(arguments: [
        (TimeInterval(3300), TimeInterval?(3600)),
        (3000, 3600),
        (600, nil)
    ])
    func `a headless commit carries the receiver's position`(position: TimeInterval, duration: TimeInterval?) {
        let request = CastMediaRequest(
            contentURL: URL(fileURLWithPath: "/movie.mp4"), contentType: "video/mp4", streamType: .buffered,
            title: "Title", subtitle: nil, posterURL: nil, startTime: 0, contentRef: .movie("m1")
        )
        let end = CastSessionEnd(reason: .stopped, lastPosition: position, duration: duration, request: request)
        #expect(PlayerCastPolicy.headlessCommit(for: end, hostAttached: false)?.position == position)
    }

    @Test(arguments: [
        (CastMediaRequest.StreamType.buffered, PlayableMedia.ContentRef.movie("m1"), true, false),
        (.buffered, .movie("m1"), false, true),
        (.buffered, .episode("e1"), false, true),
        (.live, .live("c1"), false, false),
        (.buffered, .recording("r1"), false, false)
    ])
    func `only on-demand catalog items without a player are committed headless`(
        streamType: CastMediaRequest.StreamType,
        ref: PlayableMedia.ContentRef,
        hostAttached: Bool,
        commits: Bool
    ) {
        let request = CastMediaRequest(
            contentURL: URL(fileURLWithPath: "/item"), contentType: "video/mp4", streamType: streamType,
            title: "Title", subtitle: nil, posterURL: nil, startTime: 0, contentRef: ref
        )
        let end = CastSessionEnd(reason: .stopped, lastPosition: 120, duration: 3600, request: request)
        #expect((PlayerCastPolicy.headlessCommit(for: end, hostAttached: hostAttached) != nil) == commits)
    }

    @Test func `a session resumed at launch commits nothing`() {
        let end = CastSessionEnd(reason: .finished, lastPosition: 120, duration: 3600, request: nil)
        #expect(PlayerCastPolicy.headlessCommit(for: end, hostAttached: false) == nil)
    }

    // MARK: - Headless commits

    @Test func `an item finishing with the player closed is written watched`() async throws {
        let harness = try Harness()
        try await harness.service.load(harness.request())
        harness.provider.simulatePlaying(at: 3500, duration: 3600)
        harness.provider.simulateIdle(.finished)
        await harness.settle()

        let movie = try #require(try harness.movie())
        #expect(movie.watchProgress == 3600)
        #expect(movie.isWatched)
        #expect(harness.synced == [harness.movieRef])
        #expect(harness.completedTitles == 1)
        #expect(harness.service.currentRequest == nil)
        #expect(harness.service.castingMedia == nil)
    }

    @Test func `a cast stopped short of the watched line writes its position without a sync`() async throws {
        let harness = try Harness()
        try await harness.service.load(harness.request())
        harness.provider.simulatePlaying(at: 1200, duration: 3600)
        harness.provider.simulateSessionEnd(.disconnected)
        await harness.settle()

        let movie = try #require(try harness.movie())
        #expect(movie.watchProgress == 1200)
        #expect(!movie.isWatched)
        #expect(harness.synced.isEmpty)
    }

    @Test func `a cast stopped past the watched line syncs the trackers`() async throws {
        let harness = try Harness()
        try await harness.service.load(harness.request())
        harness.provider.simulatePlaying(at: 3300, duration: 3600)
        harness.provider.simulateIdle(.stopped)
        await harness.settle()

        #expect(try harness.movie()?.isWatched == true)
        #expect(harness.synced == [harness.movieRef])
    }

    @Test func `a live channel writes no progress`() async throws {
        let harness = try Harness()
        try await harness.service.load(harness.request(live: true))
        harness.provider.simulatePlaying(at: 900, duration: nil)
        harness.provider.simulateIdle(.stopped)
        await harness.settle()

        #expect(harness.committer.pendingCommit == nil)
        #expect(try harness.channelLastWatched() == nil)
        #expect(harness.service.currentRequest == nil)
    }

    // MARK: - Host attached

    @Test func `an open player commits its own cast and the service writes nothing`() async throws {
        let harness = try Harness()
        let session = harness.makeSession()
        var outcomes: [CastEndOutcome] = []
        session.onEnd = { outcomes.append($0) }
        let request = harness.request()
        session.begin(media: harness.media(for: request), request: request)
        await session.pendingLoad?.value
        harness.provider.simulatePlaying(at: 3500, duration: 3600)
        harness.provider.simulateIdle(.finished)
        await harness.settle()

        #expect(outcomes.count == 1)
        #expect(harness.committer.pendingCommit == nil)
        #expect(try harness.movie()?.watchProgress == 0)
    }

    @Test func `stopping from the player is not committed again when the receiver reports it`() async throws {
        let harness = try Harness()
        let session = harness.makeSession()
        session.onEnd = { _ in }
        let request = harness.request()
        session.begin(media: harness.media(for: request), request: request)
        await session.pendingLoad?.value
        harness.provider.simulatePlaying(at: 1200, duration: 3600)
        session.stopCasting()
        harness.provider.simulateSessionEnd(.stopped)
        await harness.settle()

        #expect(harness.committer.pendingCommit == nil)
        #expect(harness.service.currentRequest == nil)
    }

    @Test func `closing the player hands the commit to the service`() async throws {
        let harness = try Harness()
        let session = harness.makeSession()
        let request = harness.request()
        session.begin(media: harness.media(for: request), request: request)
        await session.pendingLoad?.value
        harness.provider.simulatePlaying(at: 1800, duration: 3600)
        session.close()
        harness.provider.simulatePlaying(at: 2400, duration: 3600)
        harness.provider.simulateIdle(.stopped)
        await harness.settle()

        #expect(try harness.movie()?.watchProgress == 2400)
    }

    @Test func `a new player replacing a closed player's cast commits the old item first`() async throws {
        let harness = try Harness()
        try await harness.service.load(harness.request())
        harness.provider.simulatePlaying(at: 1500, duration: 3600)

        harness.service.attachProgressHost(owner: "player", playing: .episode("e2"))
        await harness.settle()

        #expect(try harness.movie()?.watchProgress == 1500)
    }

    @Test func `a player taking over the same item commits nothing yet`() async throws {
        let harness = try Harness()
        try await harness.service.load(harness.request())
        harness.provider.simulatePlaying(at: 1500, duration: 3600)

        harness.service.attachProgressHost(owner: "player", playing: harness.movieRef)

        #expect(harness.committer.pendingCommit == nil)
    }
}
