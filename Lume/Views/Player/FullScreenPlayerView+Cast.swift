//
//  FullScreenPlayerView+Cast.swift
//  Lume
//
//  The player host's half of a Chromecast handoff, kept out of the main file
//  (which is at its length cap). The decisions live in `PlayerCastPolicy` and
//  the state that outlives a call in `PlayerCastSession`; this wires them to
//  the host: the engine view goes while the receiver plays, item navigation
//  loads onto the receiver, and the engine comes back when the cast stops.
//
//  The hooks are iOS only. Everywhere else `CastService` never connects, so
//  `castSession` stays idle and the player behaves as it always has.
//

import SwiftUI

extension FullScreenPlayerView {
    /// The playback clock and the cast session reading the receiver into it,
    /// created together because the session needs the clock.
    static func playbackStates(adopting media: PlayableMedia) -> (State<PlaybackClock>, State<PlayerCastSession>) {
        let clock = PlaybackClock()
        return (State(initialValue: clock), State(initialValue: PlayerCastSession(clock: clock, adopting: media)))
    }

    var showsCastSurface: Bool {
        #if os(iOS)
            PlayerCastPolicy.showsCastSurface(
                isCasting: castSession.isCasting,
                connection: castService.chromecastConnection,
                isCastRequested: castService.isPlayerCastRequested
            )
        #else
            false
        #endif
    }

    /// The receiver already plays this Stalker stream from a link of its own;
    /// resolving another would spend a `create_link` on nothing.
    var castKeepsResolution: Bool {
        castSession.media?.id == activeMedia.id
    }

    @ViewBuilder
    var castingSurface: some View {
        #if os(iOS)
            CastPlaybackView(
                media: activeMedia,
                clock: clock,
                neighbours: itemNeighbours,
                onStep: { _ = advanceForRemoteCommand($0) },
                onStop: stopCastingFromPlayer,
                onClose: closePlayer
            )
            // The engine whose session this was is gone by now; the receiver
            // plays the sound.
            .task { releaseAudioSession() }
        #endif
    }

    /// Starts casting the stream on screen to the receiver the viewer picked.
    /// Returns what to tell the viewer when it can't be cast.
    func beginCast(onEnd: @escaping (CastEndOutcome) -> Void) -> LocalizedStringResource? {
        guard let media = displayMedia else { return nil }
        let verdict = castSession.publishCastability(
            for: media,
            position: clock.current,
            preferredURL: PlayerCastPolicy.preferredURL(for: media, in: modelContext)
        )
        switch verdict {
        case let .unsupported(reason):
            castService.consumePlayerCastRequest()
            castService.endSession(stopReceiver: true)
            if !activeMedia.isLive, clock.current > 1 {
                resumeActiveMedia(at: clock.current)
            }
            return reason.message
        case let .castable(request):
            persistProgressDetached(force: true)
            castSession.onEnd = onEnd
            castSession.begin(media: activeMedia, request: request, advance: remoteAdvanceHandler)
            return nil
        }
    }

    /// Takes over the cast `castSession` found running for this media when
    /// the player opened, and publishes what the stream on screen allows.
    func adoptRunningCast(onEnd: @escaping (CastEndOutcome) -> Void) {
        castSession.onEnd = onEnd
        castSession.adoptPendingCast(advance: remoteAdvanceHandler)
        _ = castDisplayedMedia()
    }

    /// The stream on screen changed — opened, resolved, or swapped by item
    /// navigation. Publishes its castability, and mid-cast plays it on the
    /// receiver instead of a local engine. Returns what to tell the viewer
    /// when the new item can't be cast and playback came back here.
    func castDisplayedMedia() -> LocalizedStringResource? {
        let media = displayMedia
        // The preferred URL only swaps one HTTP(S) URL for another, so the
        // played URL settles castability without its catalog fetches.
        castSession.publishCastability(for: media)
        guard let media, castSession.isCasting, let casting = castSession.media, casting.id != media.id else {
            return nil
        }
        let preferredURL = PlayerCastPolicy.preferredURL(for: media, in: modelContext)
        switch CastStreamResolver.verdict(for: media, preferredURL: preferredURL) {
        case let .castable(request):
            castSession.loadNext(media: activeMedia, request: request)
            return nil
        case let .unsupported(reason):
            castSession.stopCasting()
            return reason.message
        }
    }

    func stopCastingFromPlayer() {
        guard castSession.isCasting else {
            // A receiver connected for this player that the cast never
            // reached — a stream still resolving.
            castService.consumePlayerCastRequest()
            castService.endSession(stopReceiver: true)
            return
        }
        castSession.stopCasting()
    }

    /// Acts on a cast of this player's stream that stopped. Returns what to
    /// tell the viewer when the receiver failed it.
    func finishCast(_ outcome: CastEndOutcome) -> LocalizedStringResource? {
        if let progress = outcome.progress {
            commitCastProgress(progress)
        }
        switch outcome.next {
        case .resumeLocally:
            configureAudioSessionForPlayback()
            if let position = PlayerCastPolicy.localResumePosition(after: outcome, activeRef: activeMedia.contentRef) {
                resumeActiveMedia(at: position)
            }
            // A cast taken over at open never resolved the Stalker link it
            // played; the engine needs one of its own.
            if StalkerLink.isPlaceholder(activeMedia.url), resolvedMedia?.id != activeMedia.id {
                retryResolve()
            }
        case .itemFinished:
            // Settled at its full duration; the flush of the next swap or the
            // close must not walk it back.
            completedRef = activeMedia.contentRef
            let autoPlayNext = UserDefaults.standard.bool(
                PlayerSettings.Playback.autoPlayNextKey, default: PlayerSettings.Playback.autoPlayNextDefault
            )
            if autoPlayNext, let next = nextUpMedia {
                castService.requestPlayerCast()
                switchMedia(to: next)
            } else {
                castService.endSession(stopReceiver: true)
                closePlayer()
            }
        }
        return outcome.failure?.message
    }

    /// The receiver's position written through the same writer, and in the
    /// same order, as `persistProgressDetached`.
    private func commitCastProgress(_ commit: CastProgressCommit) {
        guard commit.ref != completedRef else { return }
        enqueueProgressWrite(ref: commit.ref, progress: commit.position, duration: commit.duration, force: true)
    }
}

/// Starts, follows and ends the player's casts, and tells the viewer when a
/// stream couldn't be cast. A modifier so the `CastService` state it watches
/// re-renders only this, not the player tree.
struct PlayerCastHandoff: ViewModifier {
    let host: FullScreenPlayerView

    @State private var notice: LocalizedStringResource?
    @State private var showsCastDevices = false

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                // Presented from here, not from the overlay's button: the
                // overlay leaves the tree when the controls auto-hide.
                .environment(\.showCastDevices) { showsCastDevices = true }
                .sheet(isPresented: $showsCastDevices) { CastDeviceSheet(castSession: host.castSession) }
                .onAppear { host.adoptRunningCast(onEnd: castEnded) }
                .onChange(of: beginsCast) { _, begins in
                    guard begins else { return }
                    if let message = host.beginCast(onEnd: castEnded) {
                        notice = message
                    }
                }
                .onChange(of: host.displayMedia?.id) {
                    if let message = host.castDisplayedMedia() {
                        notice = message
                    }
                }
                .onDisappear {
                    // Progress so far is the host's close flush; the receiver
                    // plays on into the mini-controller.
                    host.castSession.close()
                }
                .alert(
                    Text(CastEndOutcome.Failure.title),
                    isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                    presenting: notice,
                    actions: { _ in },
                    message: { Text($0) }
                )
        #else
            content
        #endif
    }

    private var beginsCast: Bool {
        PlayerCastPolicy.shouldBeginCast(
            connection: host.castService.chromecastConnection,
            isCastRequested: host.castService.isPlayerCastRequested,
            isCasting: host.castSession.isCasting
        ) && host.displayMedia != nil
    }

    private func castEnded(_ outcome: CastEndOutcome) {
        if let message = host.finishCast(outcome) {
            notice = message
        }
    }
}
