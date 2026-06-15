//
//  ParentalControls.swift
//  Lume
//
//  UI-facing facade for parental controls: the PIN gate. Owns whether a PIN is
//  set and verifies entries; the PIN hash itself lives in the keychain (see
//  `ParentalControlsStore`). The PIN is required to leave a child profile for a
//  non-child one, and to open Content Management — so a child can't lift the
//  restrictions a parent set. Created once in `LumeApp` and injected into the
//  environment.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class ParentalControls {
    /// The PIN length the UI collects — the platform-standard parental-gate size.
    static let pinLength = 4

    /// Mirrors the keychain so SwiftUI reacts to set/clear without a keychain read
    /// on every body. Seeded at init, updated on each mutation.
    private(set) var isPINSet: Bool

    /// Resolves the active profile so the switch gate can ask "are we leaving a
    /// child profile?". A strong reference is fine — both live for the app's life.
    private let profileManager: ProfileManager

    init(profileManager: ProfileManager) {
        self.profileManager = profileManager
        isPINSet = ParentalControlsStore.isSet
    }

    func setPIN(_ pin: String) {
        ParentalControlsStore.save(pin: pin)
        isPINSet = true
    }

    func disablePIN() {
        ParentalControlsStore.clear()
        isPINSet = false
    }

    func verify(_ pin: String) -> Bool {
        ParentalControlsStore.verify(pin: pin)
    }

    /// A PIN is required to switch *to* `target` when a PIN is set, the active
    /// profile is a child, and the target is not — i.e. when leaving the kids'
    /// profile for an unrestricted one. Switching into a child profile, or
    /// between two child profiles, never prompts.
    func requiresPIN(toSwitchTo target: UserProfile) -> Bool {
        guard isPINSet, profileManager.activeProfile?.isChild == true else { return false }
        return !target.isChild
    }

    /// Whether Content Management should be gated behind the PIN. Only a child
    /// profile is gated — a parent is already past the gate, so they manage
    /// content freely. Requires a PIN to exist; without one there's nothing to
    /// verify.
    var contentManagementLocked: Bool {
        isPINSet && profileManager.activeProfile?.isChild == true
    }
}
