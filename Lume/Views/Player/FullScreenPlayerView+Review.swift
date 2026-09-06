//
//  FullScreenPlayerView+Review.swift
//  Lume
//
//  The player's half of the App Store review prompt. It brackets the session
//  so its health can be judged, and reports the verdict when the player
//  closes. It never presents anything: the sheet is requested from the browse
//  root, once this player is genuinely gone.
//
//  `persistProgressDetached` — where a finished title is noticed — deliberately
//  only *counts*. It also runs from `onDisappear` and from the scene-phase
//  handler, so a prompt raised there would land on a screen the viewer has
//  already left, or on an app that is backgrounding.
//
//  Both brackets compile down to nothing on tvOS, where there is no review API
//  to arm for: the verdict they produce has no reader there. The call sites in
//  `FullScreenPlayerView` stay unfenced so the player body reads the same on
//  every platform.
//

import SwiftUI

extension FullScreenPlayerView {
    /// Opens the health bracket for this session. Called once per player, not
    /// per engine attempt — the window whose health matters spans startup
    /// retries, engine fallbacks and in-player episode swaps.
    ///
    /// The token is held per view rather than in the tracker, so a second
    /// player opening in another window or scene cannot overwrite this
    /// session's baseline.
    func beginReviewSession() {
        #if !os(tvOS)
            healthToken = PlaybackHealthTracker.shared.beginSession()
            AppStoreReviewPrompt.shared.notePlayerAppeared()
        #endif
    }

    /// Closes the bracket and lets the review policy judge the moment.
    ///
    /// Deferred by one turn: each engine flushes its final QoE numbers in its
    /// own `onDisappear`, and the order of those against this view's is
    /// undefined, so a synchronous snapshot would measure a truncated session.
    ///
    /// - Parameter isChildWatching: read at the call site, where the optional
    ///   `ProfileManager` this view holds is still in scope.
    func endReviewSession(isChildWatching: Bool) {
        #if !os(tvOS)
            let token = healthToken
            let pendingWrite = pendingProgressWrite
            healthToken = nil

            // The screen is clear either way, so report that first and
            // unconditionally — the policy evaluation below can wait, the "is a
            // player up" answer cannot.
            AppStoreReviewPrompt.shared.notePlayerDisappeared()

            Task {
                // A finished title is counted by the progress write, which awaits
                // an actor. Waiting for it here is what lets the session that
                // finished the third title arm on its own dismissal instead of the
                // one after it.
                await pendingWrite?.value
                let health = token.flatMap { PlaybackHealthTracker.shared.endSession($0) }
                AppStoreReviewPrompt.shared.noteSessionEnded(
                    health: health,
                    isChildProfileActive: isChildWatching
                )
            }
        #endif
    }
}
