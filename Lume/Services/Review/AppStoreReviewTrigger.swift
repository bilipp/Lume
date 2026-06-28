//
//  AppStoreReviewTrigger.swift
//  Lume
//
//  Decides *when* to ask the user for an App Store rating. The prompt itself is
//  surfaced by SwiftUI's `requestReview` action at the call site; this type owns
//  only the throttling policy, so it stays a pure, testable scalar-flag store
//  (UserDefaults) — the same shape as `RecommendationSettings`.
//

import Foundation

/// Throttling policy for the StoreKit review prompt.
///
/// Apple's guidance is to ask only after a clearly positive experience and never
/// from a button. We treat "finished watching a movie or episode" as that
/// signal, and ask once the user has finished a few of them — at most once per
/// app version, so a future update is the soonest we'd ever ask again. (StoreKit
/// independently caps the system prompt to three appearances per year and may
/// suppress it entirely, so this is best-effort on top of that.)
nonisolated enum AppStoreReviewTrigger {
    /// Finished playbacks required before the first prompt is considered.
    static let completionThreshold = 3

    /// Running count of finished movies/episodes since the last prompt.
    static let completionCountKey = "appstore.review.completionCount.v1"
    /// Marketing version the prompt was last shown for; blocks a second ask on
    /// the same version.
    static let lastPromptedVersionKey = "appstore.review.lastPromptedVersion.v1"

    /// Record a finished playback and report whether it now makes sense to ask
    /// for a review. Returns `true` at most once per app version — the caller
    /// must follow a `true` with `markPromptShown()`.
    static func registerSignificantEvent(
        defaults: UserDefaults = .standard,
        currentVersion: String = SupportInfo.appVersion
    ) -> Bool {
        let count = defaults.integer(forKey: completionCountKey) + 1
        defaults.set(count, forKey: completionCountKey)

        guard count >= completionThreshold else { return false }
        // Already asked on this version → wait for the next update.
        return defaults.string(forKey: lastPromptedVersionKey) != currentVersion
    }

    /// Mark that the prompt was shown for the current version and reset the
    /// counter, so the next prompt can't fire until another `completionThreshold`
    /// finishes accumulate on a later version.
    static func markPromptShown(
        defaults: UserDefaults = .standard,
        currentVersion: String = SupportInfo.appVersion
    ) {
        defaults.set(currentVersion, forKey: lastPromptedVersionKey)
        defaults.set(0, forKey: completionCountKey)
    }
}
