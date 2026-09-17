//
//  AppStoreReviewStore.swift
//  Lume
//
//  The device-level counters `AppStoreReviewTrigger` decides on. Small scalar
//  flags in `UserDefaults`, deliberately not a SwiftData model: the catalog
//  container backs every browse `@Query` and the CloudKit mirror must never be
//  `@Query`-bound, so neither is a home for a review counter. State is
//  per-device, not per-profile and not iCloud-synced.
//
//  Writes happen at existing boundaries only — launch, a finished title, an
//  attempt — never on a timer or per playback tick.
//
//  Every write is fenced out on tvOS, which has no review API at any layer:
//  nothing there ever reads these counters, so writing them would grow values
//  forever with no consumer. This is the one place that rule is stated.
//

import Foundation

/// Reads and writes the `appstore.review.*` counters.
nonisolated struct AppStoreReviewStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Storage keys

    /// Running count of finished movies/episodes since the last attempt.
    /// Name kept verbatim from the first implementation so counters in
    /// already-installed builds survive the update.
    private static let completionCountKey = "appstore.review.completionCount.v1"
    /// Marketing version the prompt was last attempted for.
    private static let lastPromptedVersionKey = "appstore.review.lastPromptedVersion.v1"
    private static let launchCountKey = "appstore.review.launchCount.v1"
    /// First launch of the build that introduced this key — deliberately not
    /// back-seeded from watch history, so existing users simply wait out
    /// `minimumDaysSinceInstall`.
    private static let installedAtKey = "appstore.review.installedAt.v1"
    private static let lastPromptedAtKey = "appstore.review.lastPromptedAt.v1"
    /// Seeded directly by the trimming test, so not `private`.
    static let attemptDatesKey = "appstore.review.attemptDates.v1"
    /// When the paywall was last closed. A policy input like any other, so the
    /// window it opens is covered by tests rather than living in the shim.
    private static let paywallDismissedAtKey = "appstore.review.paywallDismissedAt.v1"

    // MARK: - Reads

    var completedTitles: Int {
        defaults.integer(forKey: Self.completionCountKey)
    }

    var launches: Int {
        defaults.integer(forKey: Self.launchCountKey)
    }

    var installedAt: Date? {
        defaults.object(forKey: Self.installedAtKey) as? Date
    }

    var lastPromptedAt: Date? {
        defaults.object(forKey: Self.lastPromptedAtKey) as? Date
    }

    var lastPromptedVersion: String? {
        defaults.string(forKey: Self.lastPromptedVersionKey)
    }

    var attemptDates: [Date] {
        defaults.array(forKey: Self.attemptDatesKey) as? [Date] ?? []
    }

    var paywallDismissedAt: Date? {
        defaults.object(forKey: Self.paywallDismissedAtKey) as? Date
    }

    // MARK: - Writes

    /// Counts a launch and, on the first one after this build is installed,
    /// seeds the install date. Existing users start their seven days here
    /// rather than being back-seeded from watch history.
    func recordLaunch(now: Date = Date()) {
        #if !os(tvOS)
            if installedAt == nil {
                defaults.set(now, forKey: Self.installedAtKey)
            }
            defaults.set(launches + 1, forKey: Self.launchCountKey)
        #endif
    }

    /// Counts a finished movie or episode (the >=90% crossing).
    func recordCompletedTitle() {
        #if !os(tvOS)
            defaults.set(completedTitles + 1, forKey: Self.completionCountKey)
        #endif
    }

    /// Timestamps a paywall dismissal, so the prompt can stay out of its way.
    func recordPaywallDismissal(now: Date = Date()) {
        #if !os(tvOS)
            defaults.set(now, forKey: Self.paywallDismissedAtKey)
        #endif
    }

    /// Records that the system prompt was *requested*. StoreKit never tells us
    /// whether it actually appeared, so an attempt is all we can log — and it
    /// spends the same budget either way.
    func recordAttempt(version: String, now: Date = Date()) {
        #if !os(tvOS)
            let log = AppStoreReviewTrigger.recentAttempts(attemptDates + [now], now: now)
            defaults.set(log, forKey: Self.attemptDatesKey)
            defaults.set(now, forKey: Self.lastPromptedAtKey)
            defaults.set(version, forKey: Self.lastPromptedVersionKey)
            defaults.set(0, forKey: Self.completionCountKey)
        #endif
    }

    // MARK: - Bridging to the policy

    func inputs(
        currentVersion: String,
        sessionWasHealthy: Bool = true,
        isAppStoreBuild: Bool = true,
        isChildProfileActive: Bool = false,
        now: Date = Date()
    ) -> AppStoreReviewTrigger.Inputs {
        AppStoreReviewTrigger.Inputs(
            completedTitles: completedTitles,
            launches: launches,
            installedAt: installedAt,
            lastPromptedAt: lastPromptedAt,
            attemptDates: attemptDates,
            lastPromptedVersion: lastPromptedVersion,
            currentVersion: currentVersion,
            sessionWasHealthy: sessionWasHealthy,
            isAppStoreBuild: isAppStoreBuild,
            isChildProfileActive: isChildProfileActive,
            paywallDismissedAt: paywallDismissedAt,
            now: now
        )
    }
}
