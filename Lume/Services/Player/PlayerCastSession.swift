//
//  PlayerCastSession.swift
//  Lume
//
//  The full-screen player's side of a Chromecast handoff: whether the stream
//  on screen can be cast, starting and switching what the receiver plays, and
//  what the player does once the cast stops. The decisions are pure functions
//  on `PlayerCastPolicy`; `PlayerCastSession` holds the state that has to
//  outlive a single call — the castability verdict, the QoE hold, the Now
//  Playing transport and the observers on `CastService`.
//

import Foundation
import SwiftData

/// Watch progress to commit for an item a cast played.
nonisolated struct CastProgressCommit: Hashable {
    let ref: PlayableMedia.ContentRef
    let position: TimeInterval
    let duration: TimeInterval
}

/// What the player does once a cast it started stops.
nonisolated struct CastEndOutcome: Hashable {
    enum Next: Hashable {
        /// Rebuild the local engine: on-demand at `position`, live (`nil`) at the
        /// live edge.
        case resumeLocally(position: TimeInterval?)
        /// An on-demand item played to its end on the receiver.
        case itemFinished
    }

    enum Failure: Hashable {
        /// The receiver wouldn't load the stream.
        case loadFailed
        /// The receiver loaded the stream and then failed playing it.
        case playbackFailed
    }

    /// `nil` when there is nothing worth writing.
    let progress: CastProgressCommit?
    let next: Next
    let failure: Failure?
}

nonisolated extension CastEndOutcome.Failure {
    static var title: LocalizedStringResource {
        LocalizedStringResource(
            "player.cast.error.title",
            defaultValue: "This stream can't be cast",
            comment: "Player › Cast error: title shown when a Chromecast couldn't play the stream and playback moved back to this device."
        )
    }

    var message: LocalizedStringResource {
        switch self {
        case .loadFailed:
            LocalizedStringResource(
                "player.cast.error.load-failed",
                defaultValue: "The Cast device couldn't open it, so it's playing on this device instead.",
                comment: "Player › Cast error: the Chromecast refused to load the stream; it now plays on the phone or tablet."
            )
        case .playbackFailed:
            LocalizedStringResource(
                "player.cast.error.playback-failed",
                defaultValue: "Playback failed on the Cast device, so it's playing on this device instead.",
                comment: "Player › Cast error: the Chromecast started the stream and then failed; it now plays on the phone or tablet."
            )
        }
    }
}

/// The receiver's playhead, reduced to what `PlaybackClock` shows.
nonisolated struct CastClockReading: Hashable {
    let current: TimeInterval
    /// `nil` leaves the clock's duration as it is — live, or not known yet.
    let duration: TimeInterval?
}

extension PlaybackClock {
    /// Writes only the values that changed, so observers re-render only on a
    /// real move.
    func apply(_ reading: CastClockReading) {
        if current != reading.current {
            current = reading.current
        }
        if let duration = reading.duration, self.duration != duration {
            self.duration = duration
        }
    }
}

nonisolated enum PlayerCastPolicy {
    /// Whether the stream on screen can be cast, and the request if so.
    /// `media` is the player's display media — `nil` while a Stalker stream
    /// is still resolving. `position` is the local playhead; before the engine
    /// reports one, an on-demand cast starts at the media's own resume point.
    static func startVerdict(
        for media: PlayableMedia?,
        position: TimeInterval,
        preferredURL: URL? = nil
    ) -> CastStreamResolver.Verdict {
        guard let media else { return .unsupported(.needsResolution) }
        return CastStreamResolver.verdict(for: media, at: position > 0 ? position : nil, preferredURL: preferredURL)
    }

    static func castability(of verdict: CastStreamResolver.Verdict) -> PlayerCastability {
        switch verdict {
        case .castable: .castable
        case let .unsupported(reason): .unsupported(reason)
        }
    }

    /// The URL an Xtream live channel casts at instead of the one it plays at
    /// locally. One indexed fetch; call it at cast start, never per tick.
    static func preferredURL(for media: PlayableMedia, in context: ModelContext) -> URL? {
        guard case let .live(id) = media.contentRef,
              let stream = PlayerContentLookup.liveStream(id, in: context),
              let playlist = PlayerContentLookup.playlist(for: media.contentRef, in: context)
        else { return nil }
        return CastStreamResolver.preferredLiveURL(for: stream, playlist: playlist)
    }

    /// Whether the player starts casting now: the viewer picked a receiver
    /// for it and that receiver is connected.
    static func shouldBeginCast(
        connection: CastConnectionState,
        isCastRequested: Bool,
        isCasting: Bool
    ) -> Bool {
        connection == .connected && isCastRequested && !isCasting
    }

    /// Whether a player opening on `media` takes over a cast already playing
    /// it — reopened from the mini-controller — instead of playing locally.
    static func shouldAdoptRunningCast(
        of media: PlayableMedia,
        castingRef: PlayableMedia.ContentRef?,
        connection: CastConnectionState
    ) -> Bool {
        connection == .connected && castingRef == media.contentRef
    }

    /// What the player does after the cast of an item stopped for `reason`.
    static func endOutcome(
        reason: CastSessionEnd.Reason,
        contentRef: PlayableMedia.ContentRef,
        isLive: Bool,
        position: TimeInterval,
        duration: TimeInterval?,
        loadFailed: Bool = false
    ) -> CastEndOutcome {
        let finishedOnDemand = reason == .finished && !isLive
        let reached = finishedOnDemand ? duration ?? position : position
        let next: CastEndOutcome.Next = if finishedOnDemand {
            .itemFinished
        } else {
            .resumeLocally(position: isLive ? nil : position)
        }
        let failure: CastEndOutcome.Failure? = if loadFailed {
            .loadFailed
        } else {
            reason == .error ? .playbackFailed : nil
        }
        return CastEndOutcome(
            progress: progress(ref: contentRef, isLive: isLive, position: reached, duration: duration),
            next: next,
            failure: failure
        )
    }

    /// `nil` while the receiver has nothing playing.
    static func clockReading(for status: CastPlaybackStatus, isLive: Bool) -> CastClockReading? {
        guard status.hasMedia, status.idleReason == nil else { return nil }
        let duration = status.duration.flatMap { $0 > 0 ? $0 : nil }
        return CastClockReading(current: max(0, status.position), duration: isLive ? nil : duration)
    }

    static func progress(
        ref: PlayableMedia.ContentRef,
        isLive: Bool,
        position: TimeInterval,
        duration: TimeInterval?
    ) -> CastProgressCommit? {
        guard position > 0 else { return nil }
        return CastProgressCommit(ref: ref, position: position, duration: isLive ? 0 : duration ?? 0)
    }
}

nonisolated extension PlayerCastPolicy {
    /// Whether the player shows its casting surface instead of a local engine:
    /// while it casts, and from the moment a receiver it asked for connects —
    /// so no engine opens the stream in the gap before the cast begins.
    static func showsCastSurface(
        isCasting: Bool,
        connection: CastConnectionState,
        isCastRequested: Bool
    ) -> Bool {
        isCasting || (connection == .connected && isCastRequested)
    }

    /// Where the local engine picks up after a cast stopped with `outcome`:
    /// the receiver's position when it played the item now on screen. `nil`
    /// opens that item as it stands — live at the edge, or an item the
    /// player moved to that the receiver never played.
    static func localResumePosition(
        after outcome: CastEndOutcome,
        activeRef: PlayableMedia.ContentRef
    ) -> TimeInterval? {
        guard case let .resumeLocally(position?) = outcome.next, position > 0,
              outcome.progress?.ref == activeRef
        else { return nil }
        return position
    }
}

/// Where the cast's lock-screen transport goes. `NowPlayingService` in the
/// app, a recorder in tests.
@MainActor
protocol CastTransportTarget: AnyObject {
    func attachTransport(_ transport: NowPlayingService.Transport, owner: AnyObject)
    func detachTransport(owner: AnyObject)
}

extension NowPlayingService: CastTransportTarget {}

/// One per full-screen player. The host asks it to begin a cast once
/// `PlayerCastPolicy.shouldBeginCast` says so, tears its local engine down,
/// and acts on the `CastEndOutcome` handed to `onEnd`. Receiver status goes
/// straight into the host's `PlaybackClock`, never into host state.
///
/// Closing the player mid-cast (`close()`) leaves the receiver playing and
/// releases the QoE hold; `CastService` commits that cast's progress.
@MainActor
@Observable
final class PlayerCastSession {
    private enum Phase {
        case idle
        case casting
    }

    /// Whether this player is showing a cast rather than a local engine.
    private(set) var isCasting = false

    /// Whether the stream on screen can be cast, for the device sheet.
    private(set) var castability = PlayerCastability.castable

    /// Called once per cast that stops while the player is open — stopped
    /// from the player, by another sender, finished, failed or disconnected.
    @ObservationIgnored var onEnd: ((CastEndOutcome) -> Void)?

    /// The stream the receiver plays, while casting.
    @ObservationIgnored private(set) var media: PlayableMedia?

    /// The receiver's last load, for tests to await.
    @ObservationIgnored private(set) var pendingLoad: Task<Void, Never>?

    @ObservationIgnored private let clock: PlaybackClock
    @ObservationIgnored private let castService: CastService
    @ObservationIgnored private let transportTarget: any CastTransportTarget
    @ObservationIgnored private let setHold: @MainActor (Bool) -> Void
    @ObservationIgnored private let owner: String
    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private var lastPosition: TimeInterval = 0
    @ObservationIgnored private var lastDuration: TimeInterval?
    @ObservationIgnored private var loadGeneration = 0

    /// `adopting` is the media the player opens on. When the receiver is
    /// already playing it, the session starts out casting, so the player never
    /// builds a local engine for it; `adoptPendingCast` then takes the cast
    /// over. Side-effect free, as a view's initializer may run it repeatedly.
    init(
        clock: PlaybackClock,
        castService: CastService? = nil,
        transportTarget: (any CastTransportTarget)? = nil,
        setHold: (@MainActor (Bool) -> Void)? = nil,
        adopting opening: PlayableMedia? = nil
    ) {
        let owner = "player-cast-\(UUID().uuidString)"
        self.owner = owner
        self.clock = clock
        // Resolved here, not as default arguments, which Swift evaluates
        // outside the main actor.
        let castService = castService ?? .shared
        self.castService = castService
        self.transportTarget = transportTarget ?? NowPlayingService.shared
        // While the receiver plays, nothing plays here for QoE to measure, and
        // the engine torn down at the handoff is neither an exit before video
        // start nor a startup failure.
        self.setHold = setHold ?? { holds in
            if holds {
                PlaybackQoE.shared.suspend(for: owner, handingOff: true)
            } else {
                PlaybackQoE.shared.resume(for: owner)
            }
        }
        if let opening, PlayerCastPolicy.shouldAdoptRunningCast(
            of: opening,
            castingRef: castService.currentContentRef,
            connection: castService.chromecastConnection
        ) {
            media = opening
            isCasting = true
        }
    }

    // MARK: - Castability

    /// Publishes whether `media` can be cast for the device sheet, and returns
    /// the verdict. Call whenever the display media changes.
    @discardableResult
    func publishCastability(
        for media: PlayableMedia?,
        position: TimeInterval = 0,
        preferredURL: URL? = nil
    ) -> CastStreamResolver.Verdict {
        let verdict = PlayerCastPolicy.startVerdict(for: media, position: position, preferredURL: preferredURL)
        let castability = PlayerCastPolicy.castability(of: verdict)
        if castability != self.castability {
            self.castability = castability
        }
        return verdict
    }

    // MARK: - Lifecycle

    /// Starts casting `media` as `request`. Takes the QoE hold before
    /// returning, so call it before the local engine view goes. A load the
    /// receiver rejects comes back through `onEnd` as `.loadFailed`.
    func begin(
        media: PlayableMedia,
        request: CastMediaRequest,
        advance: ((PlayerMediaSwapper.Step) -> Bool)? = nil
    ) {
        guard phase == .idle else {
            loadNext(media: media, request: request)
            return
        }
        castService.consumePlayerCastRequest()
        attach(media: media, position: request.startTime, advance: advance)
        load(request, media: media)
    }

    /// Takes over a cast already playing `media`, without reloading it.
    /// Returns `false` when the receiver isn't playing it.
    @discardableResult
    func adoptRunningCast(
        of media: PlayableMedia,
        advance: ((PlayerMediaSwapper.Step) -> Bool)? = nil
    ) -> Bool {
        guard phase == .idle,
              PlayerCastPolicy.shouldAdoptRunningCast(
                  of: media,
                  castingRef: castService.currentContentRef,
                  connection: castService.chromecastConnection
              )
        else { return false }
        attach(media: media, position: castService.status.position, advance: advance)
        receiverStatusChanged(castService.status)
        return true
    }

    /// Completes the takeover `init(adopting:)` found, once the player is on
    /// screen. Falls back to local playback when the receiver moved on since.
    func adoptPendingCast(advance: ((PlayerMediaSwapper.Step) -> Bool)? = nil) {
        guard phase == .idle, isCasting, let media else { return }
        if !adoptRunningCast(of: media, advance: advance) {
            self.media = nil
            isCasting = false
        }
    }

    /// Plays `media` on the receiver in place of the current item — next
    /// episode, a neighbouring channel.
    func loadNext(media: PlayableMedia, request: CastMediaRequest) {
        guard phase == .casting else { return }
        self.media = media
        lastPosition = request.startTime
        lastDuration = nil
        load(request, media: media)
    }

    /// Stop Casting: the receiver stops and the stream comes back here.
    func stopCasting() {
        guard phase == .casting, let media else { return }
        finish(
            PlayerCastPolicy.endOutcome(
                reason: .stopped, contentRef: media.contentRef, isLive: media.isLive,
                position: lastPosition, duration: lastDuration
            ),
            stopReceiver: true
        )
    }

    /// The player is closing. Mid-cast, leaves the receiver playing.
    func close() {
        guard phase == .casting else { return }
        release()
        setHold(false)
    }

    // MARK: - Internals

    private func attach(
        media: PlayableMedia,
        position: TimeInterval,
        advance: ((PlayerMediaSwapper.Step) -> Bool)?
    ) {
        phase = .casting
        isCasting = true
        self.media = media
        lastPosition = position
        lastDuration = nil
        setHold(true)
        castService.attachProgressHost(owner: owner, playing: media.contentRef)
        castService.observeSessionEnd(owner: owner) { [weak self] end in
            self?.sessionEnded(end)
        }
        castService.observeStatus(owner: owner) { [weak self] status in
            self?.receiverStatusChanged(status)
        }
        transportTarget.attachTransport(makeTransport(advance: advance), owner: self)
    }

    private func makeTransport(advance: ((PlayerMediaSwapper.Step) -> Bool)?) -> NowPlayingService.Transport {
        let castService = castService
        return NowPlayingService.Transport(
            isPlaying: { castService.status.isPlaying },
            play: { castService.play() },
            pause: { castService.pause() },
            seek: { castService.seek(to: $0) },
            advance: advance
        )
    }

    private func load(_ request: CastMediaRequest, media: PlayableMedia) {
        loadGeneration += 1
        let generation = loadGeneration
        let castService = castService
        pendingLoad = Task { [weak self] in
            do throws(CastError) {
                try await castService.load(request, media: media)
            } catch {
                self?.loadFailed(error, generation: generation)
            }
        }
    }

    private func loadFailed(_ error: CastError, generation: Int) {
        guard error != .superseded, generation == loadGeneration else { return }
        guard phase == .casting, let media else { return }
        finish(
            PlayerCastPolicy.endOutcome(
                reason: .error, contentRef: media.contentRef, isLive: media.isLive,
                position: lastPosition, duration: lastDuration, loadFailed: true
            ),
            stopReceiver: true
        )
    }

    private func sessionEnded(_ end: CastSessionEnd) {
        guard phase == .casting, let media else { return }
        // The end of an item a newer load is replacing; that load's own
        // result decides what happens next.
        if let ended = end.request, ended.contentRef != media.contentRef { return }
        finish(
            PlayerCastPolicy.endOutcome(
                reason: end.reason, contentRef: media.contentRef, isLive: media.isLive,
                position: end.lastPosition, duration: end.duration ?? lastDuration
            ),
            stopReceiver: end.reason == .error
        )
    }

    private func receiverStatusChanged(_ status: CastPlaybackStatus) {
        guard phase == .casting, let media,
              let reading = PlayerCastPolicy.clockReading(for: status, isLive: media.isLive)
        else { return }
        lastPosition = reading.current
        lastDuration = reading.duration ?? lastDuration
        clock.apply(reading)
    }

    /// Ends this cast and hands `outcome` to `onEnd`. `stopReceiver` ends the
    /// receiver's session too, for a cast that can't continue there.
    private func finish(_ outcome: CastEndOutcome, stopReceiver: Bool) {
        let handler = onEnd
        release(settled: true)
        setHold(false)
        if stopReceiver {
            castService.endSession(stopReceiver: true)
        }
        handler?(outcome)
    }

    private func release(settled: Bool = false) {
        phase = .idle
        if isCasting {
            isCasting = false
        }
        onEnd = nil
        media = nil
        loadGeneration += 1
        castService.removeSessionEndObserver(owner: owner)
        castService.removeStatusObserver(owner: owner)
        castService.detachProgressHost(owner: owner, settled: settled)
        transportTarget.detachTransport(owner: self)
    }
}
