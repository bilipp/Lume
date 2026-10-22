//
//  PlayerControlsAutoHide.swift
//  Lume
//
//  Whether the player chrome may auto-hide, for the four engine views that
//  schedule the hide. A policy, not a view concern — it lives here rather than
//  on the caption leaf that motivated it.
//

import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum PlayerControlsAutoHide {
    /// Whether the host must leave its controls up rather than auto-hiding them.
    ///
    /// The ~4 s auto-hide is below WCAG 2.2.1 for a panel of text, and the
    /// stream-info caption has no affordance of its own to bring back — so while
    /// VoiceOver is running and that caption is on, the chrome stays put.
    static var isSuppressed: Bool {
        #if canImport(UIKit)
            PlayerSettings.StreamInfo.isEnabled && UIAccessibility.isVoiceOverRunning
        #elseif canImport(AppKit)
            PlayerSettings.StreamInfo.isEnabled && NSWorkspace.shared.isVoiceOverEnabled
        #else
            false
        #endif
    }

    /// Whether one of the chrome's menus (quality, audio, subtitles, speed) is
    /// open. Hiding the chrome removes the menu with it and drops the pick, so
    /// the hide holds off until the menu closes.
    static var isMenuOpen: Bool {
        menuOpenedAt.map { $0.timeIntervalSinceNow > -menuHoldLimit } ?? false
    }

    private static var menuOpenedAt: Date?

    #if os(tvOS)
        /// tvOS reports both ends of a menu through focus, so this is only a
        /// backstop.
        private static let menuHoldLimit: TimeInterval = 120
    #else
        /// SwiftUI reports a menu opening (its rows appear) but not a dismissal
        /// without a pick, so the hold lapses after this long; a pick ends it at
        /// once through the overlay's hide-timer reset.
        private static let menuHoldLimit: TimeInterval = 20
    #endif

    static func menuOpened() {
        if !isMenuOpen { menuOpenedAt = .now }
    }

    /// Any use of the chrome means no menu is open any more: a pick closes its
    /// menu, and a menu covers the rest of the chrome while it is open.
    static func menuClosed() {
        menuOpenedAt = nil
    }

    /// Suspends while a menu is open; whether there was one. The hide task
    /// calls this once its interval is up, then waits a full interval more, so
    /// the chrome hides after a dismissed menu without the menu restarting the
    /// timer — a restart from the menu could cancel the hide a row's pick just
    /// scheduled while the new stream is still starting, and pin the chrome.
    static func waitWhileMenuOpen() async -> Bool {
        guard isMenuOpen else { return false }
        while isMenuOpen, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }
}
