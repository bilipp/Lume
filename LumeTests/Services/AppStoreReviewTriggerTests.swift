import Foundation
@testable import Lume
import Testing

final class AppStoreReviewTriggerTests {
    // MARK: - Fixtures

    /// A fixed clock. Nothing here may read `Date()`: the policy's floors are
    /// measured in months, and a real clock would make the assertions depend on
    /// when the suite happens to run.
    private static let referenceNow = Date(timeIntervalSince1970: 1_750_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    private let now = AppStoreReviewTriggerTests.referenceNow

    private func daysAgo(_ count: Double) -> Date {
        now.addingTimeInterval(-count * Self.day)
    }

    /// Suites created by `makeDefaults`, torn down together so a test's
    /// counters can never leak into another test or into the shim's singleton.
    private var suiteNames: [String] = []

    deinit {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    /// A throwaway, empty `UserDefaults` domain so the policy never reads or
    /// mutates the shared standard suite.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppStoreReviewTriggerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        suiteNames.append(suiteName)
        return defaults
    }

    private func makeStore() throws -> AppStoreReviewStore {
        try AppStoreReviewStore(defaults: makeDefaults())
    }

    /// The engaged baseline the throttle and suppressor cases start from:
    /// enough completions to qualify, on a version that was never prompted,
    /// with nothing spent and no suppressor set. Each test overrides only the
    /// field it is about.
    private func engagedInputs(
        lastPromptedAt: Date? = nil,
        attemptDates: [Date] = [],
        lastPromptedVersion: String? = nil,
        sessionWasHealthy: Bool = true,
        isAppStoreBuild: Bool = true,
        isChildProfileActive: Bool = false,
        paywallDismissedAt: Date? = nil
    ) -> AppStoreReviewTrigger.Inputs {
        AppStoreReviewTrigger.Inputs(
            completedTitles: AppStoreReviewTrigger.completionThreshold,
            launches: 0,
            installedAt: nil,
            lastPromptedAt: lastPromptedAt,
            attemptDates: attemptDates,
            lastPromptedVersion: lastPromptedVersion,
            currentVersion: "2.0",
            sessionWasHealthy: sessionWasHealthy,
            isAppStoreBuild: isAppStoreBuild,
            isChildProfileActive: isChildProfileActive,
            paywallDismissedAt: paywallDismissedAt,
            now: now
        )
    }

    // MARK: - Existing cases, on the new API

    @Test func `does not ask before the completion threshold`() throws {
        let store = try makeStore()
        store.recordLaunch(now: now)
        for _ in 1 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        let verdict = AppStoreReviewTrigger.verdict(
            for: store.inputs(currentVersion: "1.0", now: now)
        )
        #expect(verdict == .skip(.notEngagedYet))
    }

    @Test func `asks once the threshold is reached`() throws {
        let store = try makeStore()
        store.recordLaunch(now: now)
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        #expect(AppStoreReviewTrigger.verdict(for: store.inputs(currentVersion: "1.0", now: now)) == .ask)
    }

    @Test func `does not ask twice on the same version`() throws {
        let store = try makeStore()
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        store.recordAttempt(version: "1.0", now: now)

        // The attempt reset the counter, so re-earn engagement and confirm the
        // version guard still blocks the same version.
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        #expect(AppStoreReviewTrigger.verdict(for: store.inputs(currentVersion: "1.0", now: now)) == .skip(.sameVersion))
    }

    @Test func `asks again after an app update and the cooldown`() throws {
        let store = try makeStore()
        let promptedAt = daysAgo(400)
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        store.recordAttempt(version: "1.0", now: promptedAt)

        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        let insideCooldown = promptedAt.addingTimeInterval(Self.day * Double(AppStoreReviewTrigger.promptCooldownDays - 1))
        let afterCooldown = promptedAt.addingTimeInterval(Self.day * Double(AppStoreReviewTrigger.promptCooldownDays + 1))

        #expect(
            AppStoreReviewTrigger.verdict(for: store.inputs(currentVersion: "1.1", now: insideCooldown))
                == .skip(.tooSoon)
        )
        #expect(AppStoreReviewTrigger.verdict(for: store.inputs(currentVersion: "1.1", now: afterCooldown)) == .ask)
    }

    // MARK: - Eligibility: the two routes

    @Test func `completions alone qualify without any launch history`() {
        let inputs = AppStoreReviewTrigger.Inputs(
            completedTitles: AppStoreReviewTrigger.completionThreshold,
            launches: 0,
            installedAt: nil,
            currentVersion: "2.0",
            now: now
        )
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .ask)
    }

    @Test func `launches over enough days qualify without any completion`() {
        let inputs = AppStoreReviewTrigger.Inputs(
            completedTitles: 0,
            launches: AppStoreReviewTrigger.launchThreshold,
            installedAt: daysAgo(Double(AppStoreReviewTrigger.minimumDaysSinceInstall)),
            currentVersion: "2.0",
            now: now
        )
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .ask)
    }

    @Test func `a half satisfied route does not qualify`() {
        let oneCompletionShort = AppStoreReviewTrigger.Inputs(
            completedTitles: AppStoreReviewTrigger.completionThreshold - 1,
            launches: AppStoreReviewTrigger.launchThreshold - 1,
            installedAt: daysAgo(400),
            currentVersion: "2.0",
            now: now
        )
        let enoughLaunchesTooNew = AppStoreReviewTrigger.Inputs(
            completedTitles: 0,
            launches: AppStoreReviewTrigger.launchThreshold,
            installedAt: daysAgo(Double(AppStoreReviewTrigger.minimumDaysSinceInstall) - 1),
            currentVersion: "2.0",
            now: now
        )
        let oldEnoughTooFewLaunches = AppStoreReviewTrigger.Inputs(
            completedTitles: 0,
            launches: AppStoreReviewTrigger.launchThreshold - 1,
            installedAt: daysAgo(400),
            currentVersion: "2.0",
            now: now
        )
        let launchesButNoInstallDate = AppStoreReviewTrigger.Inputs(
            completedTitles: 0,
            launches: AppStoreReviewTrigger.launchThreshold * 10,
            installedAt: nil,
            currentVersion: "2.0",
            now: now
        )

        #expect(AppStoreReviewTrigger.verdict(for: oneCompletionShort) == .skip(.notEngagedYet))
        #expect(AppStoreReviewTrigger.verdict(for: enoughLaunchesTooNew) == .skip(.notEngagedYet))
        #expect(AppStoreReviewTrigger.verdict(for: oldEnoughTooFewLaunches) == .skip(.notEngagedYet))
        #expect(AppStoreReviewTrigger.verdict(for: launchesButNoInstallDate) == .skip(.notEngagedYet))
    }

    // MARK: - Throttle

    @Test func `the time floor blocks a prompt until the cooldown elapses`() {
        func verdict(daysSincePrompt: Double) -> AppStoreReviewTrigger.Verdict {
            AppStoreReviewTrigger.verdict(
                for: engagedInputs(
                    lastPromptedAt: daysAgo(daysSincePrompt),
                    attemptDates: [daysAgo(daysSincePrompt)],
                    lastPromptedVersion: "1.0"
                )
            )
        }

        let floor = Double(AppStoreReviewTrigger.promptCooldownDays)
        #expect(verdict(daysSincePrompt: 1) == .skip(.tooSoon))
        #expect(verdict(daysSincePrompt: floor - 1) == .skip(.tooSoon))
        #expect(verdict(daysSincePrompt: floor) == .ask)
        #expect(verdict(daysSincePrompt: floor + 1) == .ask)
    }

    @Test func `there is no time floor before the first attempt`() {
        let inputs = engagedInputs(lastPromptedAt: nil)
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .ask)
    }

    @Test func `the same version is blocked even once the cooldown has elapsed`() {
        let inputs = engagedInputs(
            lastPromptedAt: daysAgo(400),
            attemptDates: [daysAgo(400)],
            lastPromptedVersion: "2.0"
        )
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .skip(.sameVersion))
    }

    @Test func `the rolling budget blocks a fourth attempt inside the window`() {
        func verdict(attemptDates: [Date]) -> AppStoreReviewTrigger.Verdict {
            AppStoreReviewTrigger.verdict(
                for: engagedInputs(
                    lastPromptedAt: daysAgo(130),
                    attemptDates: attemptDates,
                    lastPromptedVersion: "1.0"
                )
            )
        }

        let window = Double(AppStoreReviewTrigger.attemptWindowDays)
        let spent = [daysAgo(130), daysAgo(260), daysAgo(window - 1)]
        #expect(verdict(attemptDates: spent) == .skip(.budgetSpent))

        // Same three attempts, but the oldest has aged out of the window.
        let oneAgedOut = [daysAgo(130), daysAgo(260), daysAgo(window + 1)]
        #expect(verdict(attemptDates: oneAgedOut) == .ask)
    }

    @Test func `the attempt log only counts the trailing window`() {
        let dates = [daysAgo(1), daysAgo(200), daysAgo(400), daysAgo(1000)]
        let recent = AppStoreReviewTrigger.recentAttempts(dates, now: now)
        #expect(recent == [daysAgo(1), daysAgo(200)])
    }

    // MARK: - Hard suppressors

    @Test func `a build without an App Store listing never asks`() {
        let inputs = engagedInputs(isAppStoreBuild: false)
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .skip(.notAppStoreBuild))
    }

    @Test func `an active child profile never asks`() {
        let inputs = engagedInputs(isChildProfileActive: true)
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .skip(.childProfile))
    }

    @Test func `an unhealthy playback session never asks`() {
        let inputs = engagedInputs(sessionWasHealthy: false)
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .skip(.unhealthyPlayback))
    }

    @Test func `a recently dismissed paywall never asks`() {
        let inputs = engagedInputs(paywallDismissedAt: now.addingTimeInterval(-30 * 60))
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .skip(.recentPaywall))
    }

    @Test func `the paywall window expires`() {
        let elapsed = (AppStoreReviewTrigger.paywallSuppressionHours + 1) * 60 * 60
        let inputs = engagedInputs(paywallDismissedAt: now.addingTimeInterval(-elapsed))
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .ask)
    }

    @Test func `a paywall that was never opened does not suppress`() {
        let inputs = engagedInputs(paywallDismissedAt: nil)
        #expect(AppStoreReviewTrigger.verdict(for: inputs) == .ask)
    }

    // MARK: - Persistence

    @Test func `counts each launch once and seeds the install date only once`() throws {
        let store = try makeStore()
        let firstLaunch = daysAgo(30)
        store.recordLaunch(now: firstLaunch)
        store.recordLaunch(now: daysAgo(20))
        store.recordLaunch(now: now)

        #expect(store.launches == 3)
        #expect(store.installedAt == firstLaunch)
    }

    @Test func `recording an attempt stamps the version and resets the counter`() throws {
        let store = try makeStore()
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        store.recordAttempt(version: "2.0", now: now)

        #expect(store.completedTitles == 0)
        #expect(store.lastPromptedVersion == "2.0")
        #expect(store.lastPromptedAt == now)
        #expect(store.attemptDates == [now])
    }

    @Test func `recording an attempt trims the stored log to the window`() throws {
        let defaults = try makeDefaults()
        let store = AppStoreReviewStore(defaults: defaults)
        let window = Double(AppStoreReviewTrigger.attemptWindowDays)
        defaults.set(
            [daysAgo(window + 10), daysAgo(200)],
            forKey: AppStoreReviewStore.attemptDatesKey
        )

        store.recordAttempt(version: "2.0", now: now)

        #expect(store.attemptDates == [now, daysAgo(200)])
    }
}

// MARK: - Session health

/// The gate that decides whether the policy above is ever consulted. Pure, so
/// it needs no player, no engine and no simulator — only two snapshots.
final class PlaybackSessionHealthTests {
    /// Comfortably past `minimumWatchedSeconds`, so these cases turn on the
    /// fault being measured rather than on the short-session exclusion.
    private let watched = PlaybackSessionHealth.minimumWatchedSeconds * 10

    private func snapshot(
        engineFallbacks: Int = 0,
        startupFailures: Int = 0,
        rebufferSeconds: TimeInterval = 0,
        watchedSeconds: TimeInterval = 0
    ) -> PlaybackHealthSnapshot {
        var snapshot = PlaybackHealthSnapshot()
        snapshot.engineFallbacks = engineFallbacks
        snapshot.startupFailures = startupFailures
        snapshot.rebufferSeconds = rebufferSeconds
        snapshot.watchedSeconds = watchedSeconds
        return snapshot
    }

    @Test func `a clean session of decent length is healthy`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(watchedSeconds: watched)
        )
        #expect(verdict == .healthy)
    }

    /// The whole reason the tracker diffs instead of reading the summary: a
    /// user with a lifetime of faults behind them can still have a clean
    /// session, and must still be askable.
    @Test func `faults already on the clock do not taint a clean session`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(engineFallbacks: 12, startupFailures: 30, rebufferSeconds: 900),
            to: snapshot(
                engineFallbacks: 12,
                startupFailures: 30,
                rebufferSeconds: 900,
                watchedSeconds: watched
            )
        )
        #expect(verdict == .healthy)
    }

    @Test func `an engine fallback during the session is unhealthy`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(engineFallbacks: 1),
            to: snapshot(engineFallbacks: 2, watchedSeconds: watched)
        )
        #expect(verdict == .unhealthy(.engineFallback))
    }

    @Test func `a startup failure during the session is unhealthy`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(startupFailures: 4),
            to: snapshot(startupFailures: 5, watchedSeconds: watched)
        )
        #expect(verdict == .unhealthy(.startupFailure))
    }

    @Test func `rebuffering past the ceiling is unhealthy`() {
        let stalled = watched * (PlaybackSessionHealth.rebufferRatioCeiling + 0.01)
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(rebufferSeconds: stalled, watchedSeconds: watched)
        )
        #expect(verdict == .unhealthy(.rebuffering))
    }

    @Test func `rebuffering under the ceiling is still healthy`() {
        let stalled = watched * (PlaybackSessionHealth.rebufferRatioCeiling - 0.01)
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(rebufferSeconds: stalled, watchedSeconds: watched)
        )
        #expect(verdict == .healthy)
    }

    /// A session too short to judge is deliberately *not* healthy: a diff of
    /// zeros would otherwise read as flawless and arm a prompt off a viewer who
    /// opened a channel and immediately left.
    @Test func `a session below the watch floor is not measured`() {
        let verdict = PlaybackSessionHealth.verdict(
            from: snapshot(),
            to: snapshot(watchedSeconds: PlaybackSessionHealth.minimumWatchedSeconds - 1)
        )
        #expect(verdict == .notMeasured(.tooShort))
        #expect(verdict.isHealthy == false)
    }

    @Test func `only the healthy verdict may arm a prompt`() {
        #expect(PlaybackSessionHealth.healthy.isHealthy)
        #expect(PlaybackSessionHealth.unhealthy(.rebuffering).isHealthy == false)
        #expect(PlaybackSessionHealth.notMeasured(.suspended).isHealthy == false)
    }
}

// MARK: - Session brackets

/// The tracker's bookkeeping, not the verdict maths. Two players can be open at
/// once — macOS gives the player its own window, iPadOS its own scene — and a
/// single-slot tracker let the second one clobber the first one's baseline, so
/// the first was judged against the wrong snapshot and the second inherited a
/// verdict it had not earned.
@MainActor
final class PlaybackHealthTrackerTests {
    /// QoE is a shared singleton, so every test leaves its suspension flag the
    /// way it found it — restored inside the test body, never in `deinit`,
    /// which is nonisolated and cannot touch main-actor state. Nothing here
    /// calls `reset()`, which would persist to the standard defaults suite.
    init() {
        PlaybackQoE.shared.isSuspended = false
    }

    @Test func `concurrent sessions get their own brackets`() {
        let first = PlaybackHealthTracker.shared.beginSession()
        let second = PlaybackHealthTracker.shared.beginSession()
        #expect(first != second)

        // Closing the second must leave the first's bracket open, which is
        // exactly what a single slot could not do.
        #expect(PlaybackHealthTracker.shared.endSession(second) != nil)
        #expect(PlaybackHealthTracker.shared.endSession(first) != nil)
    }

    @Test func `a closed session cannot be closed twice`() {
        let token = PlaybackHealthTracker.shared.beginSession()
        #expect(PlaybackHealthTracker.shared.endSession(token) != nil)
        // No stale verdict to inherit: the bracket is gone, not merely stale.
        #expect(PlaybackHealthTracker.shared.endSession(token) == nil)
    }

    @Test func `a session that began while QoE was suspended is not measured`() {
        PlaybackQoE.shared.isSuspended = true
        let token = PlaybackHealthTracker.shared.beginSession()
        PlaybackQoE.shared.isSuspended = false
        #expect(PlaybackHealthTracker.shared.endSession(token) == .notMeasured(.suspended))
    }

    @Test func `a suspended session stays unmeasured even if it began clear`() {
        let token = PlaybackHealthTracker.shared.beginSession()
        PlaybackQoE.shared.isSuspended = true
        defer { PlaybackQoE.shared.isSuspended = false }
        #expect(PlaybackHealthTracker.shared.endSession(token) == .notMeasured(.suspended))
    }
}

// MARK: - Shim bookkeeping

/// The arm/hold side of the prompt. `RequestReviewAction` cannot be
/// constructed, so firing itself is out of reach — but every decision that
/// leads up to it is reachable, because the shim takes an injectable
/// `UserDefaults` and exposes what it armed.
@MainActor
final class AppStoreReviewPromptTests {
    private var suiteNames: [String] = []

    deinit {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    /// A shim on a throwaway defaults suite, never the shared singleton.
    private func makePrompt() throws -> (AppStoreReviewPrompt, AppStoreReviewStore) {
        let suiteName = "AppStoreReviewPromptTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        suiteNames.append(suiteName)
        return (AppStoreReviewPrompt(defaults: defaults), AppStoreReviewStore(defaults: defaults))
    }

    /// Enough finished titles to satisfy the completion route on its own.
    private func makeEngaged() throws -> AppStoreReviewPrompt {
        let (prompt, store) = try makePrompt()
        for _ in 0 ..< AppStoreReviewTrigger.completionThreshold {
            store.recordCompletedTitle()
        }
        return prompt
    }

    // MARK: Screen bookkeeping

    @Test func `two concurrent players both have to close before the screen is clear`() throws {
        let (prompt, _) = try makePrompt()
        #expect(prompt.playerIsVisible == false)

        prompt.notePlayerAppeared()
        prompt.notePlayerAppeared()
        prompt.notePlayerDisappeared()
        // The second player is still up: a Bool would have said otherwise.
        #expect(prompt.playerIsVisible)

        prompt.notePlayerDisappeared()
        #expect(prompt.playerIsVisible == false)
    }

    @Test func `a presented paywall is not a safe moment`() throws {
        let (prompt, _) = try makePrompt()
        #expect(prompt.paywallIsVisible == false)

        prompt.notePaywallAppeared()
        #expect(prompt.paywallIsVisible)

        prompt.notePaywallDismissed()
        #expect(prompt.paywallIsVisible == false)
    }

    @Test func `an unbalanced close cannot drive a count negative`() throws {
        let (prompt, _) = try makePrompt()
        prompt.notePlayerDisappeared()
        prompt.notePaywallDismissed()
        #expect(prompt.playerIsVisible == false)
        #expect(prompt.paywallIsVisible == false)
    }

    // MARK: Arming

    @Test func `a healthy session by an engaged viewer arms`() throws {
        let prompt = try makeEngaged()
        prompt.noteSessionEnded(health: .healthy, isChildProfileActive: false)
        #expect(prompt.isArmed)
    }

    @Test func `an unhealthy session does not arm`() throws {
        let prompt = try makeEngaged()
        prompt.noteSessionEnded(health: .unhealthy(.engineFallback), isChildProfileActive: false)
        #expect(prompt.isArmed == false)
    }

    @Test func `a session with no verdict does not arm`() throws {
        let prompt = try makeEngaged()
        prompt.noteSessionEnded(health: nil, isChildProfileActive: false)
        #expect(prompt.isArmed == false)
    }

    @Test func `a child profile does not arm`() throws {
        let prompt = try makeEngaged()
        prompt.noteSessionEnded(health: .healthy, isChildProfileActive: true)
        #expect(prompt.isArmed == false)
    }

    @Test func `a viewer who has not engaged yet does not arm`() throws {
        let (prompt, _) = try makePrompt()
        prompt.noteSessionEnded(health: .healthy, isChildProfileActive: false)
        #expect(prompt.isArmed == false)
    }

    /// The reason `recentPaywall` was moved into the policy: a paywall closed
    /// between the arm and the fire has to be able to hold it back, and the
    /// arm has to survive that hold rather than being spent on it.
    @Test func `a paywall closed after arming still blocks the fire`() throws {
        let prompt = try makeEngaged()
        prompt.noteSessionEnded(health: .healthy, isChildProfileActive: false)
        #expect(prompt.isArmed)

        prompt.notePaywallAppeared()
        prompt.notePaywallDismissed()

        // Still armed, and still inside the window — the fire point re-runs the
        // policy, so it will decline until the window passes.
        #expect(prompt.isArmed)
        #expect(prompt.paywallIsVisible == false)
    }
}
