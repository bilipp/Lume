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
}
