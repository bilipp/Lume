//
//  IntentRouter.swift
//  Lume
//
//  The one in-memory slot a Siri intent's link waits in until the app can act
//  on it. It is a singleton rather than `MainTabView` state because an intent
//  can run while the launch gate (sync choice, sign-in, profile picker, PIN pad)
//  is still up and `MainTabView` hasn't mounted. Never persisted: a request
//  that outlives the process would replay on a later, unrelated launch.
//

import Foundation

/// A Siri request waiting for the screen to clear.
struct PendingIntent: Equatable {
    let link: DeepLink
    /// Playback started this way defers the cold-launch automatic sync.
    let startedBySiri: Bool
}

@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()

    enum Outcome: Equatable {
        /// Resolve the link for the profile now active and play it.
        case play(PendingIntent)
        /// Show the `.siri` paywall; the request stays pending for an upgrade.
        case showPaywall
    }

    private(set) var pending: PendingIntent?
    /// The paywall is up for `pending`; it isn't shown a second time.
    private(set) var isAwaitingUpgrade = false

    var hasPending: Bool {
        pending != nil
    }

    /// Queues `link`. A newer request replaces one still waiting.
    func enqueue(_ link: DeepLink, startedBySiri: Bool) {
        pending = PendingIntent(link: link, startedBySiri: startedBySiri)
        isAwaitingUpgrade = false
    }

    /// Hands the waiting request over once `screenIsClear`. The returned link
    /// was resolved for whoever was active when Siri ran, so the caller
    /// re-resolves it through `WidgetLinkResolver` for the current profile.
    /// - Returns: nil while the screen is blocked, nothing is waiting, or the
    ///   paywall is already up for the request.
    func consumePending(screenIsClear: Bool, isPremium: Bool? = nil) -> Outcome? {
        guard screenIsClear, let request = pending else { return nil }
        guard PremiumManager.isPremium(isPremium) else {
            guard !isAwaitingUpgrade else { return nil }
            isAwaitingUpgrade = true
            return .showPaywall
        }
        reset()
        return .play(request)
    }

    /// The `.siri` paywall closed. Without an upgrade the request is dropped;
    /// with one it stays for the next `consumePending`.
    func paywallDismissed(isPremium: Bool? = nil) {
        guard isAwaitingUpgrade else { return }
        if PremiumManager.isPremium(isPremium) {
            isAwaitingUpgrade = false
        } else {
            reset()
        }
    }

    /// Drops `request` if it is still the one waiting; a newer one stays.
    func withdraw(_ request: PendingIntent) {
        guard pending == request else { return }
        clear()
    }

    func clear() {
        reset()
    }

    private func reset() {
        pending = nil
        isAwaitingUpgrade = false
    }
}
