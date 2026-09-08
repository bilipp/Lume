//
//  AppStoreReviewTrigger.swift
//  Lume
//
//  Decides *whether* to ask the user for an App Store rating. Nothing here
//  imports StoreKit, touches UserDefaults or reads a clock: every input is
//  injected and the answer is a value, so the whole policy is testable without
//  a ModelContainer, a real install date or the system prompt.
//
//  The prompt itself is Apple's system sheet, fired by the shim that owns
//  `requestReview`. Persistence lives in `AppStoreReviewStore`.
//

import Foundation

/// Whether the moment is right for the system rating prompt.
///
/// `requestReview()` returns `Void` and never reports whether the sheet
/// actually appeared — StoreKit silently no-ops past its own cap of three
/// appearances per 365 days. So everything below is best-effort on top of that
/// cap, and what we record is an *attempt*, not a show.
nonisolated enum AppStoreReviewTrigger {
    // MARK: - Policy constants

    /// Finished movies/episodes that make a user "engaged" on their own.
    static let completionThreshold = 3
    /// Launches required by the second route — the one that reaches a Live TV
    /// only user, who never produces a VOD completion.
    static let launchThreshold = 5
    /// Days since install required alongside `launchThreshold`.
    static let minimumDaysSinceInstall = 7
    /// Days that must pass after an attempt before another one is considered.
    static let promptCooldownDays = 120
    /// Attempts allowed inside `attemptWindowDays`, mirroring StoreKit's own
    /// per-year cap so we never burn it on a mediocre moment.
    static let attemptBudget = 3
    /// Rolling window the attempt log is trimmed and counted over.
    static let attemptWindowDays = 365
    /// How long after a paywall dismissal the prompt stays quiet, so it never
    /// reads as "we just took your money". Roughly one sitting — a purchase
    /// itself is neutral, it is only the adjacency that would sting.
    static let paywallSuppressionHours = 2.0

    // MARK: - Inputs

    /// Everything the decision depends on, injected by the caller.
    nonisolated struct Inputs: Equatable {
        var completedTitles: Int
        var launches: Int
        /// `nil` before the store has seeded it; disables the launch route.
        var installedAt: Date?
        /// `nil` when we have never attempted a prompt — no time floor then.
        var lastPromptedAt: Date?
        var attemptDates: [Date]
        var lastPromptedVersion: String?
        /// Always injected — never read from `SupportInfo` in here, which
        /// returns a placeholder when `CFBundleShortVersionString` is missing
        /// and would silently become a stored version.
        var currentVersion: String
        var sessionWasHealthy: Bool
        var isAppStoreBuild: Bool
        var isChildProfileActive: Bool
        /// `nil` when the paywall has never been closed on this device.
        var paywallDismissedAt: Date?
        var now: Date

        init(
            completedTitles: Int,
            launches: Int,
            installedAt: Date?,
            lastPromptedAt: Date? = nil,
            attemptDates: [Date] = [],
            lastPromptedVersion: String? = nil,
            currentVersion: String,
            sessionWasHealthy: Bool = true,
            isAppStoreBuild: Bool = true,
            isChildProfileActive: Bool = false,
            paywallDismissedAt: Date? = nil,
            now: Date
        ) {
            self.completedTitles = completedTitles
            self.launches = launches
            self.installedAt = installedAt
            self.lastPromptedAt = lastPromptedAt
            self.attemptDates = attemptDates
            self.lastPromptedVersion = lastPromptedVersion
            self.currentVersion = currentVersion
            self.sessionWasHealthy = sessionWasHealthy
            self.isAppStoreBuild = isAppStoreBuild
            self.isChildProfileActive = isChildProfileActive
            self.paywallDismissedAt = paywallDismissedAt
            self.now = now
        }
    }

    // MARK: - Verdict

    /// Why we are not asking. Raw values are what a QA log prints.
    nonisolated enum Reason: String, Equatable {
        case notEngagedYet
        case tooSoon
        case sameVersion
        case budgetSpent
        case unhealthyPlayback
        case notAppStoreBuild
        case childProfile
        case recentPaywall
    }

    nonisolated enum Verdict: Equatable {
        case ask
        case skip(Reason)
    }

    // MARK: - Decision

    static func verdict(for inputs: Inputs) -> Verdict {
        guard inputs.isAppStoreBuild else { return .skip(.notAppStoreBuild) }
        guard !inputs.isChildProfileActive else { return .skip(.childProfile) }
        guard inputs.sessionWasHealthy else { return .skip(.unhealthyPlayback) }

        if let paywallDismissedAt = inputs.paywallDismissedAt,
           hours(from: paywallDismissedAt, to: inputs.now) < paywallSuppressionHours
        {
            return .skip(.recentPaywall)
        }

        guard isEngaged(inputs) else { return .skip(.notEngagedYet) }
        guard inputs.lastPromptedVersion != inputs.currentVersion else { return .skip(.sameVersion) }

        if let lastPromptedAt = inputs.lastPromptedAt,
           days(from: lastPromptedAt, to: inputs.now) < Double(promptCooldownDays)
        {
            return .skip(.tooSoon)
        }

        guard recentAttemptCount(inputs.attemptDates, now: inputs.now) < attemptBudget else {
            return .skip(.budgetSpent)
        }

        return .ask
    }

    /// Either route qualifies: enough finished titles, or enough launches over
    /// enough days. The second route is the only one a Live TV only user can
    /// ever satisfy — the >=90% completion crossing is VOD-only.
    static func isEngaged(_ inputs: Inputs) -> Bool {
        if inputs.completedTitles >= completionThreshold { return true }
        guard let installedAt = inputs.installedAt else { return false }
        return inputs.launches >= launchThreshold
            && days(from: installedAt, to: inputs.now) >= Double(minimumDaysSinceInstall)
    }

    /// How many attempts fall inside the rolling window — all the verdict
    /// needs. Dates in the future (clock skew) are counted, which only ever
    /// suppresses a prompt.
    static func recentAttemptCount(_ dates: [Date], now: Date) -> Int {
        let cutoff = attemptCutoff(now: now)
        return dates.count { $0 > cutoff }
    }

    /// Attempts inside the rolling window, newest first: the trimmer the store
    /// writes back with, so the log can't grow without bound.
    static func recentAttempts(_ dates: [Date], now: Date) -> [Date] {
        let cutoff = attemptCutoff(now: now)
        return dates.filter { $0 > cutoff }.sorted(by: >)
    }

    // MARK: - Private

    private static let secondsPerDay: Double = 24 * 60 * 60

    private static func attemptCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(attemptWindowDays) * secondsPerDay)
    }

    private static func days(from start: Date, to end: Date) -> Double {
        end.timeIntervalSince(start) / secondsPerDay
    }

    private static func hours(from start: Date, to end: Date) -> Double {
        end.timeIntervalSince(start) / (60 * 60)
    }
}
