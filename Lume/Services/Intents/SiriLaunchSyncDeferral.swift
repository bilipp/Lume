//
//  SiriLaunchSyncDeferral.swift
//  Lume
//
//  Holds the automatic playlist sync while a stream Siri asked for on a cold
//  launch plays. Single-connection Xtream/Stalker accounts can't run a catalog
//  sync and a stream at once, so the sync waits until that player closes (or
//  the request turns out not to play) and then runs. Memory only: a deferral
//  never outlives the process.
//

import Foundation

@MainActor
@Observable
final class SiriLaunchSyncDeferral {
    static let shared = SiriLaunchSyncDeferral()

    enum Phase: Equatable {
        case none
        /// The Siri request is waiting (launch gate, paywall) or routing.
        case awaitingPlayback
        /// Its player is up.
        case playing
    }

    private(set) var phase: Phase = .none
    /// Whether the launch auto-sync gate has run in this process. A request
    /// that arrives after it isn't a cold launch: the sync already had its turn.
    private var launchGateHasRun = false

    var isDeferring: Bool {
        phase != .none
    }

    nonisolated static func shouldDefer(startedBySiri: Bool, coldLaunch: Bool, playbackActive: Bool) -> Bool {
        startedBySiri && coldLaunch && playbackActive
    }

    /// Where `phase` goes once the request's state is known. `resumesSync` is
    /// true exactly when the held sync should run now.
    nonisolated static func next(
        _ phase: Phase,
        requestPending: Bool,
        playerIsVisible: Bool
    ) -> (phase: Phase, resumesSync: Bool) {
        switch phase {
        case .none:
            (.none, false)
        case .awaitingPlayback:
            if playerIsVisible {
                (.playing, false)
            } else if requestPending {
                (.awaitingPlayback, false)
            } else {
                (.none, true)
            }
        case .playing:
            playerIsVisible ? (.playing, false) : (.none, true)
        }
    }

    /// The automatic sync gate. True holds every automatic sync, the launch
    /// pass and the foreground/playlist re-checks alike, until `update` says
    /// the deferral is over.
    func holdsAutoSync() -> Bool {
        holdsAutoSync(pending: IntentRouter.shared.pending, playerIsVisible: ScreenOccupancy.shared.playerIsVisible)
    }

    func holdsAutoSync(pending: PendingIntent?, playerIsVisible: Bool) -> Bool {
        let coldLaunch = !launchGateHasRun
        launchGateHasRun = true
        guard phase == .none else { return true }
        let playbackActive = pending != nil || playerIsVisible
        guard Self.shouldDefer(
            startedBySiri: pending?.startedBySiri == true,
            coldLaunch: coldLaunch,
            playbackActive: playbackActive
        ) else { return false }
        phase = .awaitingPlayback
        return true
    }

    /// Advances the deferral.
    /// - Returns: true when the held sync should run now.
    func update(requestPending: Bool, playerIsVisible: Bool) -> Bool {
        let (next, resumesSync) = Self.next(phase, requestPending: requestPending, playerIsVisible: playerIsVisible)
        phase = next
        return resumesSync
    }
}
