//
//  PlayerMenuControlsHold.swift
//  Lume
//
//  Keeps the player chrome up while one of its menus is open, so a pick isn't
//  raced by the ~4 s auto-hide. The engine views' hide tasks wait on
//  `PlayerControlsAutoHide.waitWhileMenuOpen()` before hiding.
//

import SwiftUI

extension View {
    /// Apply to a player Menu's rows: on iOS and visionOS they appear when the
    /// menu opens. tvOS builds a menu's rows along with the chrome, before
    /// anything opens, so `TVPlayerControlsOverlay` follows its menus through
    /// focus instead. macOS is unverified (its rows may be built eagerly too,
    /// which would hold every chrome reveal), so it keeps the plain auto-hide.
    @ViewBuilder
    func holdsPlayerControls() -> some View {
        #if os(tvOS) || os(macOS)
            self
        #else
            onAppear { PlayerControlsAutoHide.menuOpened() }
        #endif
    }
}
