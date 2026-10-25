import Foundation
@testable import Lume
import Testing

private enum CastSessionFixture {
    static func media(
        _ url: String = "http://example.com/movie/u/p/1.mp4",
        kind: PlayableMedia.Kind = .vod,
        startTime: TimeInterval = 0,
        contentRef: PlayableMedia.ContentRef = .movie("m1"),
        httpHeaders: [String: String]? = nil
    ) -> PlayableMedia {
        PlayableMedia(
            id: "item-\(contentRef)",
            url: URL(string: url) ?? URL(fileURLWithPath: "/invalid"),
            title: "Title",
            subtitle: nil,
            posterURL: nil,
            kind: kind,
            startTime: startTime,
            contentRef: contentRef,
            httpHeaders: httpHeaders
        )
    }

    static let movie = media()
    static let channel = media("http://example.com/live/u/p/7.m3u8", kind: .live, contentRef: .live("c7"))
    static let nextEpisode = media("http://example.com/series/u/p/2.mp4", contentRef: .episode("e2"))
}

/// The player host's side of a Chromecast handoff: where a cast starts, what
/// the player does when it stops, and the holds it keeps while it runs.
@MainActor
struct PlayerCastSessionTests {
    @MainActor
    private final class TransportRecorder: CastTransportTarget {
        private(set) var transport: NowPlayingService.Transport?
        private(set) var owner: ObjectIdentifier?
        private(set) var detachCount = 0

        func attachTransport(_ transport: NowPlayingService.Transport, owner: AnyObject) {
            self.transport = transport
            self.owner = ObjectIdentifier(owner)
        }

        func detachTransport(owner: AnyObject) {
            guard self.owner == ObjectIdentifier(owner) else { return }
            transport = nil
            self.owner = nil
            detachCount += 1
        }
    }

    @MainActor
    private final class Harness {
        let provider = StubCastProvider()
        let service: CastService
        let clock = PlaybackClock()
        let transports = TransportRecorder()
        var holds: [Bool] = []
        var outcomes: [CastEndOutcome] = []
        var session: PlayerCastSession!

        init(connected: Bool = true) {
            service = CastService(castProvider: provider)
            if connected {
                provider.simulateConnection(.connected)
            }
            session = makeSession()
        }

        func makeSession(adopting media: PlayableMedia? = nil) -> PlayerCastSession {
            let session = PlayerCastSession(
                clock: clock, castService: service, transportTarget: transports,
                setHold: { [weak self] in self?.holds.append($0) },
                adopting: media
            )
            session.onEnd = { [weak self] in self?.outcomes.append($0) }
            return session
        }

        var isHeld: Bool {
            holds.last ?? false
        }

        func begin(_ media: PlayableMedia, at position: TimeInterval = 0) async throws {
            guard case let .castable(request) = PlayerCastPolicy.startVerdict(for: media, position: position) else {
                Issue.record("\(media.url) should be castable")
                return
            }
            session.begin(media: media, request: request)
            await session.pendingLoad?.value
        }
    }

    // MARK: - Start decision

    @Test(arguments: [
        (CastSessionFixture.movie, 754.0, 754.0),
        (CastSessionFixture.movie, 0.0, 0.0),
        (CastSessionFixture.media(startTime: 300), 0.0, 300.0),
        (CastSessionFixture.media(startTime: 300), 42.0, 42.0),
        (CastSessionFixture.channel, 754.0, 0.0)
    ])
    func `an on-demand cast starts at the playhead and live at the edge`(
        media: PlayableMedia,
        position: TimeInterval,
        expectedStart: TimeInterval
    ) {
        let verdict = PlayerCastPolicy.startVerdict(for: media, position: position)
        guard case let .castable(request) = verdict else {
            Issue.record("expected castable, got \(verdict)")
            return
        }
        #expect(request.startTime == expectedStart)
    }

    @Test func `a stream still resolving can't be cast yet`() {
        #expect(PlayerCastPolicy.startVerdict(for: nil, position: 0) == .unsupported(.needsResolution))
    }

    @Test(arguments: [
        (CastSessionFixture.media("file:///var/mobile/Downloads/movie.mp4"), CastStreamResolver.Reason.localFile),
        (CastSessionFixture.media("http://rec.local/r/1.m3u8", contentRef: .recording("r1")), .recording),
        (CastSessionFixture.media("http://dav.local/movie.mp4", httpHeaders: ["Authorization": "Basic x"]), .headerAuth),
        (CastSessionFixture.media("rtmp://live.example.com/app/stream", kind: .live), .unsupportedProtocol)
    ])
    func `an uncastable stream publishes its reason`(media: PlayableMedia, reason: CastStreamResolver.Reason) {
        let harness = Harness()
        harness.session.publishCastability(for: media)

        #expect(harness.session.castability == .unsupported(reason))
        #expect(harness.session.castability.unsupportedReason == reason)
    }

    @Test func `a castable stream publishes castable`() {
        let harness = Harness()
        harness.session.publishCastability(for: CastSessionFixture.media("rtmp://live.example.com/app/stream", kind: .live))
        harness.session.publishCastability(for: CastSessionFixture.movie)
        #expect(harness.session.castability == .castable)
    }

    @Test func `a preferred URL replaces the played one for the cast`() throws {
        let hls = try #require(URL(string: "http://example.com/live/u/p/7.m3u8"))
        let mpegTS = CastSessionFixture.media("http://example.com/live/u/p/7.ts", kind: .live, contentRef: .live("c7"))
        let verdict = PlayerCastPolicy.startVerdict(for: mpegTS, position: 0, preferredURL: hls)
        guard case let .castable(request) = verdict else {
            Issue.record("expected castable, got \(verdict)")
            return
        }
        #expect(request.contentURL == hls)
    }

    @Test(arguments: [
        (CastConnectionState.connected, true, false, true),
        (.connected, false, false, false),
        (.connected, true, true, false),
        (.connecting, true, false, false),
        (.idle, true, false, false)
    ])
    func `the player casts once the receiver it asked for connects`(
        connection: CastConnectionState,
        requested: Bool,
        casting: Bool,
        begins: Bool
    ) {
        #expect(PlayerCastPolicy.shouldBeginCast(
            connection: connection, isCastRequested: requested, isCasting: casting
        ) == begins)
    }

    @Test func `picking a receiver requests a cast that the connection drop clears`() {
        let harness = Harness(connected: false)
        harness.service.connect(to: CastDevice(id: "d1", name: "TV", modelName: nil, kind: .television))
        #expect(harness.service.isPlayerCastRequested)

        harness.provider.simulateConnection(.idle)
        #expect(!harness.service.isPlayerCastRequested)
    }

    // MARK: - End outcomes

    @Test(arguments: [
        (CastSessionEnd.Reason.stopped, false, CastEndOutcome.Next.resumeLocally(position: 600), nil),
        (.disconnected, false, .resumeLocally(position: 600), nil),
        (.error, false, .resumeLocally(position: 600), CastEndOutcome.Failure.playbackFailed),
        (.finished, false, .itemFinished, nil),
        (.stopped, true, .resumeLocally(position: nil), nil),
        (.error, true, .resumeLocally(position: nil), .playbackFailed),
        (.finished, true, .resumeLocally(position: nil), nil)
    ] as [(CastSessionEnd.Reason, Bool, CastEndOutcome.Next, CastEndOutcome.Failure?)])
    func `the end reason decides how playback continues`(
        reason: CastSessionEnd.Reason,
        isLive: Bool,
        next: CastEndOutcome.Next,
        failure: CastEndOutcome.Failure?
    ) {
        let outcome = PlayerCastPolicy.endOutcome(
            reason: reason, contentRef: .movie("m1"), isLive: isLive, position: 600, duration: 3600
        )
        #expect(outcome.next == next)
        #expect(outcome.failure == failure)
    }

    @Test func `a finished item commits its full duration`() {
        let outcome = PlayerCastPolicy.endOutcome(
            reason: .finished, contentRef: .episode("e1"), isLive: false, position: 3590, duration: 3600
        )
        #expect(outcome.progress == CastProgressCommit(ref: .episode("e1"), position: 3600, duration: 3600))
    }

    @Test(arguments: [3300.0, 3000.0])
    func `a stopped cast commits the receiver's position`(position: TimeInterval) {
        let outcome = PlayerCastPolicy.endOutcome(
            reason: .stopped, contentRef: .movie("m1"), isLive: false, position: position, duration: 3600
        )
        #expect(outcome.progress == CastProgressCommit(ref: .movie("m1"), position: position, duration: 3600))
    }

    @Test func `a live cast commits no duration`() {
        let outcome = PlayerCastPolicy.endOutcome(
            reason: .stopped, contentRef: .live("c7"), isLive: true, position: 4000, duration: 4000
        )
        #expect(outcome.progress == CastProgressCommit(ref: .live("c7"), position: 4000, duration: 0))
    }

    @Test func `a cast that never played commits nothing`() {
        let outcome = PlayerCastPolicy.endOutcome(
            reason: .error, contentRef: .movie("m1"), isLive: false, position: 0, duration: nil, loadFailed: true
        )
        #expect(outcome.progress == nil)
        #expect(outcome.failure == .loadFailed)
        #expect(outcome.next == .resumeLocally(position: 0))
    }

    @Test func `a resumed session Lume didn't load has nothing to commit`() {
        let end = CastSessionEnd(reason: .finished, lastPosition: 100, duration: 200, request: nil)
        #expect(PlayerCastPolicy.headlessCommit(for: end, hostAttached: false) == nil)
    }

    @Test(arguments: [
        (CastPlaybackStatus(hasMedia: true, position: 12, duration: 3600, isPlaying: true,
                            isBuffering: false, volume: 1, idleReason: nil), false,
         CastClockReading(current: 12, duration: 3600) as CastClockReading?),
        (CastPlaybackStatus(hasMedia: true, position: 12, duration: nil, isPlaying: true,
                            isBuffering: false, volume: 1, idleReason: nil), false,
         CastClockReading(current: 12, duration: nil)),
        (CastPlaybackStatus(hasMedia: true, position: 12, duration: 3600, isPlaying: true,
                            isBuffering: false, volume: 1, idleReason: nil), true,
         CastClockReading(current: 12, duration: nil)),
        (CastPlaybackStatus.idle, false, nil)
    ])
    func `receiver status maps onto the clock`(
        status: CastPlaybackStatus,
        isLive: Bool,
        reading: CastClockReading?
    ) {
        #expect(PlayerCastPolicy.clockReading(for: status, isLive: isLive) == reading)
    }

    // MARK: - Session lifecycle

    @Test func `beginning a cast holds QoE, attaches the transport and loads the receiver`() async throws {
        let harness = Harness()
        harness.service.requestPlayerCast()
        try await harness.begin(CastSessionFixture.movie, at: 754)

        #expect(harness.session.isCasting)
        #expect(harness.holds == [true])
        #expect(harness.transports.transport != nil)
        #expect(harness.provider.calls == [.load(CastSessionFixture.movie.url)])
        #expect(harness.service.castingMedia == CastSessionFixture.movie)
        #expect(harness.service.currentContentRef == CastSessionFixture.movie.contentRef)
        #expect(harness.service.currentRequest?.startTime == 754)
        #expect(!harness.service.isPlayerCastRequested)
    }

    @Test func `the transport drives the receiver`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        let transport = try #require(harness.transports.transport)

        transport.pause()
        transport.play()
        transport.seek(90)

        #expect(harness.provider.calls.suffix(3) == [.pause, .play, .seek(90)])
    }

    @Test func `receiver status reaches the clock`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)

        harness.provider.simulatePlaying(at: 321, duration: 3600)

        #expect(harness.clock.current == 321)
        #expect(harness.clock.duration == 3600)
    }

    @Test func `stop casting resumes locally at the receiver's position`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 1200, duration: 3600)

        harness.session.stopCasting()

        #expect(harness.outcomes == [CastEndOutcome(
            progress: CastProgressCommit(ref: .movie("m1"), position: 1200, duration: 3600),
            next: .resumeLocally(position: 1200),
            failure: nil
        )])
        #expect(harness.provider.calls.last == .endSession(stopReceiver: true))
        #expect(harness.holds == [true, false])
        #expect(harness.transports.transport == nil)
        #expect(!harness.session.isCasting)
    }

    @Test func `a receiver error falls back locally with a message and ends the cast`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 500, duration: 3600)

        harness.provider.simulateIdle(.error)

        let outcome = try #require(harness.outcomes.first)
        #expect(outcome.failure == .playbackFailed)
        #expect(outcome.next == .resumeLocally(position: 500))
        #expect(harness.provider.calls.last == .endSession(stopReceiver: true))
        #expect(harness.holds == [true, false])
        #expect(harness.transports.detachCount == 1)
    }

    @Test func `a rejected load falls back locally at the start position`() async throws {
        let harness = Harness()
        harness.provider.loadFailure = .loadFailed
        try await harness.begin(CastSessionFixture.movie, at: 754)

        #expect(harness.outcomes.map(\.failure) == [.loadFailed])
        #expect(harness.outcomes.map(\.next) == [.resumeLocally(position: 754)])
        #expect(harness.provider.calls.last == .endSession(stopReceiver: true))
        #expect(harness.holds == [true, false])
        #expect(harness.service.castingMedia == nil)
    }

    @Test func `a superseded load is not a failure`() async throws {
        let harness = Harness()
        harness.provider.loadFailure = .superseded
        try await harness.begin(CastSessionFixture.movie)

        #expect(harness.outcomes.isEmpty)
        #expect(harness.session.isCasting)
    }

    @Test func `a finished item ends the cast without reloading locally`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 3590, duration: 3600)

        harness.provider.simulateIdle(.finished)

        let outcome = try #require(harness.outcomes.first)
        #expect(outcome.next == .itemFinished)
        #expect(!harness.provider.calls.contains(.endSession(stopReceiver: true)))
        #expect(harness.holds == [true, false])
    }

    @Test func `a lost connection resumes a live channel at the edge`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.channel)
        harness.provider.simulatePlaying(at: 80, duration: nil)

        harness.provider.simulateSessionEnd(.disconnected)

        #expect(harness.outcomes.map(\.next) == [.resumeLocally(position: nil)])
        #expect(harness.outcomes.map(\.failure) == [nil])
        #expect(harness.holds == [true, false])
    }

    @Test func `loading the next item keeps casting`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        guard case let .castable(request) = PlayerCastPolicy.startVerdict(for: CastSessionFixture.nextEpisode, position: 0) else {
            Issue.record("next episode should be castable")
            return
        }

        harness.session.loadNext(media: CastSessionFixture.nextEpisode, request: request)
        await harness.session.pendingLoad?.value

        #expect(harness.provider.calls == [.load(CastSessionFixture.movie.url), .load(CastSessionFixture.nextEpisode.url)])
        #expect(harness.session.media == CastSessionFixture.nextEpisode)
        #expect(harness.service.castingMedia == CastSessionFixture.nextEpisode)
        #expect(harness.holds == [true])
        #expect(harness.outcomes.isEmpty)
    }

    // MARK: - Closing while casting

    @Test func `closing the player keeps the receiver playing and releases the hold`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 3300, duration: 3600)

        harness.session.close()

        #expect(!harness.session.isCasting)
        #expect(!harness.provider.calls.contains { if case .endSession = $0 { true } else { false } })
        #expect(harness.holds == [true, false])
        #expect(harness.transports.transport == nil)
        #expect(harness.service.castingMedia == CastSessionFixture.movie)
        #expect(harness.service.isChromecastActive)
    }

    @Test func `a receiver stopping after the player closed reaches no player`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 100)
        harness.session.close()
        harness.session = nil

        harness.provider.simulateIdle(.stopped)

        #expect(harness.holds == [true, false])
        #expect(harness.outcomes.isEmpty)
        #expect(harness.service.castingMedia == nil)
    }

    @Test func `a reopened player takes over the running cast`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 200)
        harness.session.close()

        let reopened = harness.makeSession()
        #expect(reopened.adoptRunningCast(of: CastSessionFixture.movie))
        #expect(reopened.isCasting)
        #expect(harness.clock.current == 200)
        #expect(harness.transports.transport != nil)
        #expect(harness.provider.calls == [.load(CastSessionFixture.movie.url)])

        reopened.stopCasting()
        #expect(harness.holds.last == false)
        #expect(harness.outcomes.map(\.next) == [.resumeLocally(position: 200)])
    }

    @Test func `a player on another item doesn't take over the cast`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)

        let other = harness.makeSession()
        #expect(!other.adoptRunningCast(of: CastSessionFixture.nextEpisode))
        #expect(!other.isCasting)
    }

    @Test func `closing a player that isn't casting releases nothing`() {
        let harness = Harness()
        harness.session.close()
        #expect(harness.holds.isEmpty)
    }
}

// MARK: - Player host

extension PlayerCastSessionTests {
    @Test(arguments: [
        (true, CastConnectionState.idle, false, true),
        (false, .connected, true, true),
        (false, .connecting, true, false),
        (false, .connected, false, false),
        (false, .idle, false, false)
    ])
    func `the casting surface covers the cast and the connected request before it`(
        isCasting: Bool,
        connection: CastConnectionState,
        requested: Bool,
        shows: Bool
    ) {
        #expect(PlayerCastPolicy.showsCastSurface(
            isCasting: isCasting, connection: connection, isCastRequested: requested
        ) == shows)
    }

    @Test(arguments: [
        (CastEndOutcome.Next.resumeLocally(position: 754), PlayableMedia.ContentRef.movie("m1"), 754.0 as TimeInterval?),
        (.resumeLocally(position: 754), .episode("e2"), nil),
        (.resumeLocally(position: nil), .movie("m1"), nil),
        (.itemFinished, .movie("m1"), nil)
    ])
    func `local playback resumes at the receiver's position only for the item it played`(
        next: CastEndOutcome.Next,
        activeRef: PlayableMedia.ContentRef,
        expected: TimeInterval?
    ) {
        let outcome = CastEndOutcome(
            progress: CastProgressCommit(ref: .movie("m1"), position: 754, duration: 3600),
            next: next,
            failure: nil
        )
        #expect(PlayerCastPolicy.localResumePosition(after: outcome, activeRef: activeRef) == expected)
    }

    @Test func `a cast that never played resumes the item as it stands`() {
        let outcome = PlayerCastPolicy.endOutcome(
            reason: .stopped, contentRef: .movie("m1"), isLive: false, position: 0, duration: nil
        )
        #expect(PlayerCastPolicy.localResumePosition(after: outcome, activeRef: .movie("m1")) == nil)
    }

    @Test func `a player opening on the cast item starts out casting without touching it`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.provider.simulatePlaying(at: 200)
        harness.session.close()
        let holdsBefore = harness.holds

        let reopened = harness.makeSession(adopting: CastSessionFixture.movie)

        #expect(reopened.isCasting)
        #expect(reopened.media == CastSessionFixture.movie)
        #expect(harness.holds == holdsBefore)

        reopened.adoptPendingCast()
        #expect(reopened.isCasting)
        #expect(harness.clock.current == 200)
        #expect(harness.transports.transport != nil)
        #expect(harness.provider.calls == [.load(CastSessionFixture.movie.url)])
    }

    @Test func `a player opening on another item plays locally`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.session.close()

        let other = harness.makeSession(adopting: CastSessionFixture.nextEpisode)
        #expect(!other.isCasting)
        #expect(other.media == nil)
    }

    @Test func `a takeover the receiver moved on from falls back to local playback`() async throws {
        let harness = Harness()
        try await harness.begin(CastSessionFixture.movie)
        harness.session.close()
        let reopened = harness.makeSession(adopting: CastSessionFixture.movie)

        harness.provider.simulateIdle(.stopped)
        reopened.adoptPendingCast()

        #expect(!reopened.isCasting)
        #expect(reopened.media == nil)
        #expect(harness.transports.transport == nil)
    }
}
