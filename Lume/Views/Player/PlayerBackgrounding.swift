//
//  PlayerBackgrounding.swift
//  Lume
//
//  What the full-screen engines do when the app leaves the foreground, and
//  when a PiP window that outlived it goes away. Shared so every engine
//  follows the same rule.
//

import SwiftUI

enum PlayerBackgrounding {
    /// Whether moving to `phase` should pause the engine. Never while PiP
    /// carries the stream. On iOS only a real `.background` move counts:
    /// `.inactive` comes first, before automatic PiP has started (pausing
    /// there froze the stream in the PiP window), and it also fires for
    /// Control Center and the app switcher.
    static func shouldPause(for phase: ScenePhase, pipActive: Bool = false) -> Bool {
        guard !pipActive else { return false }
        #if os(iOS)
            return phase == .background
        #else
            return phase != .active
        #endif
    }

    #if os(iOS)
        /// Call when the engine's PiP window has just gone away. Restoring PiP
        /// brings the app forward before the window goes, so a PiP that ends
        /// with the app still in the background was closed with its ✕. The
        /// user has stopped watching, so `closePlayer` ends the session rather
        /// than leaving the stream mounted behind the Home screen with a paused
        /// lock-screen player.
        static func pictureInPictureDidStop(closePlayer: () -> Void) {
            guard UIApplication.shared.applicationState == .background else { return }
            // The app can be suspended before the dismissal reaches the host's
            // `onDisappear`, so take the lock-screen player down right away.
            NowPlayingService.shared.endSession()
            closePlayer()
        }
    #endif
}
