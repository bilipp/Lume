//
//  AppStoreReviewPrompt.swift
//  Lume
//
//  Owns the rating prompt's decision to ask. The sheet itself is requested by
//  `AppStoreReviewPromptModifier`, which holds the `RequestReviewAction`; those
//  two are the only files that import StoreKit for review.
//
//  It gathers the inputs `AppStoreReviewTrigger` cannot see for itself — the
//  marketing version, the build channel, the active profile, whether this run
//  is a UI test or a preview — and turns the verdict into an *arm*, never an
//  immediate ask.
//
//  Arm now, fire later: the moment is judged when a playback session ends,
//  but the sheet is only requested once the player is gone and the browse UI
//  is back with nothing over it. Asking at the completion crossing itself
//  would land the alert on a screen the user has already left, or on an app
//  that is backgrounding — that write path also runs from `onDisappear` and
//  from the scene-phase handler.
//
//  tvOS has no review API at any layer, so everything below compiles down to
//  a no-op there. The fences are compile-time on purpose: every deployment
//  floor is already above the API floor, so there is nothing to check at run
//  time — and `RequestReviewAction` is unavailable on tvOS *as a type*, which
//  a `#available` check could not fence out. Only the two paths that are
//  genuinely platform-shaped are fenced here — the policy run and the fire
//  path; the counters are no-ops at the storage boundary instead
//  (`AppStoreReviewStore`).
//

import Foundation
import Observation
import OSLog

#if !os(tvOS)
    // `RequestReviewAction` lives in the StoreKit/SwiftUI cross-import overlay,
    // so it only resolves with both modules imported.
    import StoreKit
    import SwiftUI
#endif

/// Arms and fires Apple's system rating sheet.
///
/// `@Observable` for one reason: the browse root has to notice the player
/// closing to know its moment has arrived, and the player is presented from
/// eleven different call sites, none of which the browse root can see.
@MainActor
@Observable
final class AppStoreReviewPrompt {
    static let shared = AppStoreReviewPrompt()

    /// What an armed moment remembers about the session that earned it, so the
    /// policy can be re-run at fire time against fresh dates. Deliberately in
    /// memory only: an arm that outlived the launch it was earned in would
    /// surface far from the event that justified it.
    private struct ArmedMoment {
        var isChildProfileActive: Bool
    }

    private var armedMoment: ArmedMoment?

    /// Whether a good moment is waiting for a safe one to fire in.
    var isArmed: Bool {
        armedMoment != nil
    }

    /// How many full-screen players are on screen. A count, not a flag: on
    /// macOS the player is its own `WindowGroup` and on iPadOS the app can run
    /// several scenes, so two can be open at once and closing one must not
    /// report the screen as clear while the other is still playing.
    private var openPlayerCount = 0

    /// Whether any full-screen player is on screen. The fire point can't infer
    /// this from its own presentation state: on macOS the player is a separate
    /// `WindowGroup`, so the browse UI stays visible for the whole movie.
    var playerIsVisible: Bool {
        openPlayerCount > 0
    }

    /// How many paywalls are on screen. Counted the same way and for the same
    /// reason as players: `paywall(isPresented:)` has a dozen call sites, and
    /// the browse root that fires the prompt can see none of them.
    private var openPaywallCount = 0

    /// Whether a paywall is on screen right now. Distinct from the policy's
    /// `recentPaywall` window, which covers the two hours *after* one closes.
    var paywallIsVisible: Bool {
        openPaywallCount > 0
    }

    /// How many blocking sheets that the browse root cannot see are on screen.
    /// Counted the same way as players and paywalls: Settings is raised from
    /// the library toolbar, so the tab root has no binding for it.
    private var openBlockingSheetCount = 0

    /// Whether such a sheet is on screen right now.
    var blockingSheetIsVisible: Bool {
        openBlockingSheetCount > 0
    }

    private let store: AppStoreReviewStore

    init(defaults: UserDefaults = .standard) {
        store = AppStoreReviewStore(defaults: defaults)
    }

    // MARK: - Arming

    /// A full-screen player or Multi-View grid opened. Multi-View reports
    /// itself too, from inside `MultiViewScreen`: its presentation sites are
    /// invisible to the browse root, and a rating sheet must not animate in
    /// over a four-up grid.
    func notePlayerAppeared() {
        openPlayerCount += 1
    }

    /// A full-screen player or Multi-View grid closed. Separate from
    /// `noteSessionEnded` because Multi-View produces no health verdict to
    /// judge — and because the screen being clear must be recorded at once,
    /// while judging the moment can wait for a pending progress write.
    func notePlayerDisappeared() {
        openPlayerCount = max(0, openPlayerCount - 1)
    }

    /// Counts a finished movie or episode (the >=90% crossing). Only the count
    /// is taken here: the verdict also needs the session's health, which does
    /// not exist until the player has torn down and the engines have flushed
    /// their final QoE numbers.
    func noteCompletedTitle() {
        store.recordCompletedTitle()
    }

    /// A full-screen player closed. This is the arming point for both routes:
    /// a viewer who finished three titles, and the Live TV only viewer who
    /// never finishes one but has been launching the app for a week. Judging
    /// only at the completion crossing would leave that second route — the one
    /// that exists for Lume's primary use case — permanently unreachable.
    ///
    /// - Parameters:
    ///   - sessionHealth: verdict for the session that just ended; `nil` when
    ///     it produced no verdict. Anything but `.healthy` blocks the arm.
    ///   - isChildProfileActive: `ProfileManager.activeProfileIsChild`, passed
    ///     in rather than fetched — `UserProfile` lives in the CloudKit mirror
    ///     container, which this layer must not open a second handle to.
    func noteSessionEnded(health: PlaybackSessionHealth?, isChildProfileActive: Bool) {
        #if !os(tvOS)
            if isAutomatedRun {
                Logger.review.debug("Review prompt skipped: automatedRun")
                return
            }

            let inputs = store.inputs(
                currentVersion: currentVersion,
                sessionWasHealthy: health?.isHealthy ?? false,
                isAppStoreBuild: isAppStoreBuild,
                isChildProfileActive: isChildProfileActive
            )

            switch AppStoreReviewTrigger.verdict(for: inputs) {
            case .ask:
                armedMoment = ArmedMoment(isChildProfileActive: isChildProfileActive)
            case let .skip(reason):
                Logger.review.debug("Review prompt skipped: \(reason.rawValue, privacy: .public)")
            }
        #endif
    }

    // MARK: - Firing

    #if !os(tvOS)
        /// Requests the system sheet if one is armed.
        ///
        /// Call this only from a moment that is genuinely safe — player fully
        /// dismissed, browse UI visible, nothing presented over it, app active.
        /// The action is a parameter rather than a stored property because
        /// `RequestReviewAction` is unavailable on tvOS as a type, and a stored
        /// one would fail that build with no caller at all.
        ///
        /// The arm survives a suppressed fire: it is in-memory and dies with
        /// the launch anyway, so discarding it because the user happened to
        /// glance at the paywall would silently cost a moment they earned.
        /// It is cleared only once the prompt is actually requested.
        /// The whole policy is re-evaluated here, not just the process-local
        /// suppressors. Minutes can pass between the arm and a safe moment —
        /// long enough to open and close the paywall, which is exactly the
        /// adjacency `recentPaywall` exists to prevent and which an arm-time
        /// check alone would miss.
        ///
        /// - Returns: the reason the arm is still held, or `nil` when the sheet
        ///   was requested — or when nothing was armed at all. The fire point
        ///   needs it to tell a hold that time can lift from one that is fixed
        ///   for the rest of the launch.
        @discardableResult
        func fireIfArmed(_ requestReview: RequestReviewAction) -> AppStoreReviewTrigger.Reason? {
            guard let moment = armedMoment else { return nil }

            if isAutomatedRun {
                Logger.review.debug("Review prompt held: automatedRun")
                return nil
            }

            // `sessionWasHealthy` is left at its `true` default: a moment is
            // only ever armed off a healthy session, since anything else skips
            // with `.unhealthyPlayback`.
            let inputs = store.inputs(
                currentVersion: currentVersion,
                isAppStoreBuild: isAppStoreBuild,
                isChildProfileActive: moment.isChildProfileActive
            )

            if case let .skip(reason) = AppStoreReviewTrigger.verdict(for: inputs) {
                Logger.review.debug("Review prompt held: \(reason.rawValue, privacy: .public)")
                return reason
            }

            armedMoment = nil

            // `requestReview()` returns Void and never reports whether the
            // sheet appeared, so this records an attempt, not a show.
            if persistsAttempts { store.recordAttempt(version: currentVersion) }
            requestReview()
            return nil
        }

        /// How long until the paywall-adjacency window lifts, for a fire point
        /// that has just been held by `.recentPaywall` — the one hold that
        /// clears on its own inside a launch, so it earns a single
        /// precisely-timed retry rather than a poll.
        var paywallRetryDelay: Duration? {
            guard let dismissedAt = store.paywallDismissedAt else { return nil }
            let window = AppStoreReviewTrigger.paywallSuppressionHours * 60 * 60
            let remaining = window - Date().timeIntervalSince(dismissedAt)
            guard remaining > 0 else { return nil }
            // Over-waits by a second: there is only one retry, and a wake that
            // lands a hair short of the window would spend it on a re-decline.
            return .seconds(remaining + 1)
        }
    #endif

    // MARK: - Blocking sheets

    /// A sheet the browse root cannot see was presented over it — Settings,
    /// which presents sheets of its own several levels down (add playlist,
    /// playlist sync, the debug mail and share sheets) that not even Settings'
    /// own presenter can see.
    func noteBlockingSheetAppeared() {
        openBlockingSheetCount += 1
    }

    /// That sheet was dismissed.
    func noteBlockingSheetDismissed() {
        openBlockingSheetCount = max(0, openBlockingSheetCount - 1)
    }

    // MARK: - Paywall

    /// A paywall was presented.
    func notePaywallAppeared() {
        openPaywallCount += 1
    }

    /// The paywall was dismissed, opening the window the policy keeps clear of
    /// it.
    func notePaywallDismissed() {
        openPaywallCount = max(0, openPaywallCount - 1)
        store.recordPaywallDismissal()
    }

    // MARK: - Launch

    /// Counts this launch for the policy's second eligibility route, and seeds
    /// the install date on the first one. Routed through the shim rather than
    /// written straight from the app entry point, so every `appstore.review.*`
    /// write goes through `AppStoreReviewStore`.
    func noteAppLaunched() {
        // `.task` on the scene root runs once per process, but a second
        // window (macOS File > New Window, iPadOS multi-scene) re-runs that
        // body — and this counts launches, not scenes.
        guard !didCountLaunch else { return }
        didCountLaunch = true
        store.recordLaunch()
    }

    private var didCountLaunch = false

    // MARK: - Inputs the policy cannot see

    /// The one suppressor that is about *this process* rather than the user's
    /// history, so it cannot be an `Inputs` field. Everything datable — the
    /// paywall window included — lives in the policy where tests can reach it.
    ///
    /// A stray system alert breaks LumeUITests non-deterministically, and since
    /// every UI test selects by English literal the failure reads as "gear not
    /// hittable" rather than as an alert.
    private var isAutomatedRun: Bool {
        CommandLine.arguments.contains("-ui-testing")
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Read here, never inside the policy: this is `"—"` when
    /// `CFBundleShortVersionString` is missing, and that must not silently
    /// become a stored `lastPromptedVersion` behind the policy's back.
    private var currentVersion: String {
        SupportInfo.appVersion
    }

    /// Sideloaded / self-compiled builds are re-signed and have no App Store
    /// listing to review at all.
    private var isAppStoreBuild: Bool {
        #if SIDE_LOAD
            false
        #else
            true
        #endif
    }

    /// Whether a fire is written back to the throttle.
    ///
    /// StoreKit shows the sheet unconditionally in development and spends none
    /// of Apple's own cap, so recording the attempt there would only stamp a
    /// 120-day cooldown and a version into the developer's own defaults —
    /// making the moment visible exactly once per machine.
    private var persistsAttempts: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }
}
