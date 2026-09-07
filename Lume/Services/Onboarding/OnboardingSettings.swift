//
//  OnboardingSettings.swift
//  Lume
//
//  Storage keys and the first-launch decision for the "How Lume Works" guide,
//  persisted in `UserDefaults` (via `@AppStorage`). Pure logic only — nothing
//  here reads storage, so the decision stays testable.
//

import Foundation

nonisolated enum OnboardingSettings {
    /// Highest guide version already seen on this device. Device-local on
    /// purpose: a guide already read on this device says nothing about the
    /// user's other devices, so it is deliberately not mirrored to CloudKit.
    ///
    /// An `Int` rather than a `Bool` so a future rewritten guide can raise
    /// `currentVersion` and show itself again.
    static let seenVersionKey = "onboarding.seenVersion.v1"
    static let seenVersionDefault = 0

    /// Version of the guide this build ships.
    static let currentVersion = 1

    /// - Parameter hasPriorUsage: the caller's upgrade-suppression signal —
    ///   CloudKit-mirrored user state showing real usage before this build.
    static func needsOnboarding(seenVersion: Int, isUITesting: Bool, hasPriorUsage: Bool) -> Bool {
        guard !isUITesting, !hasPriorUsage else { return false }
        return seenVersion < currentVersion
    }
}
