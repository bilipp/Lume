//
//  AppStoreReviewPromptModifier.swift
//  Lume
//
//  Fires an already-armed rating sheet at the first genuinely safe moment.
//
//  "Safe" is four conditions at once: the app is active, the browse UI is on
//  screen, nothing of its own is presented over it, and no player is up. The
//  last one cannot be read from a presentation binding — the player is opened
//  from eleven call sites, and on macOS it is a separate window entirely — so
//  it comes from `AppStoreReviewPrompt.playerIsVisible` instead.
//
//  tvOS has no review API at any layer, so this compiles down to `self` there.
//  The fence is compile-time because `RequestReviewAction` is unavailable on
//  tvOS *as a type*: an `@Environment(\.requestReview)` declaration outside the
//  fence fails that build even with nothing calling it, which no `#available`
//  check could prevent.
//

import SwiftUI

#if !os(tvOS)
    // `RequestReviewAction` lives in the StoreKit/SwiftUI cross-import overlay,
    // so it only resolves with both modules imported.
    import StoreKit
#endif

extension View {
    /// Requests the system rating sheet here once one has been armed.
    ///
    /// - Parameter isBlocked: whether this view currently has a sheet, cover or
    ///   blocking overlay of its own on screen.
    func appStoreReviewPrompt(isBlocked: Bool) -> some View {
        #if os(tvOS)
            self
        #else
            modifier(AppStoreReviewPromptModifier(isBlocked: isBlocked))
        #endif
    }
}

#if !os(tvOS)
    private struct AppStoreReviewPromptModifier: ViewModifier {
        @Environment(\.requestReview) private var requestReview
        @Environment(\.scenePhase) private var scenePhase

        let isBlocked: Bool

        /// Long enough for a dismissal transition to finish and the browse UI to
        /// settle, so the alert doesn't animate in over a closing player.
        private static let settleDelay: Duration = .seconds(1)

        /// Reading the prompt's own state here is what subscribes this view to
        /// a player or paywall opening and closing anywhere in the app — none of
        /// which the browse root can see for itself.
        ///
        /// `isArmed` is part of the condition rather than only a guard inside
        /// the task: an arm that lands while everything else is already safe
        /// still has to start one, and keying on the environment alone would
        /// leave it waiting for a change that never comes.
        private var canFire: Bool {
            scenePhase == .active
                && !isBlocked
                && !AppStoreReviewPrompt.shared.playerIsVisible
                && !AppStoreReviewPrompt.shared.paywallIsVisible
                && !AppStoreReviewPrompt.shared.blockingSheetIsVisible
                && AppStoreReviewPrompt.shared.isArmed
        }

        func body(content: Content) -> some View {
            content
                // Keyed on the whole condition rather than driven by `onChange`
                // handlers: any part of it going false cancels a pending fire
                // instead of leaving it to land on the wrong screen.
                .task(id: canFire) {
                    guard canFire else { return }
                    try? await Task.sleep(for: Self.settleDelay)
                    guard !Task.isCancelled else { return }

                    // A hold is re-offered for `recentPaywall` alone: every
                    // other reason is fixed for this launch — a version match,
                    // a spent budget, a 120-day floor — so a second look would
                    // re-read the counters only to decline again.
                    guard let reason = AppStoreReviewPrompt.shared.fireIfArmed(requestReview),
                          reason == .recentPaywall,
                          let retryDelay = AppStoreReviewPrompt.shared.paywallRetryDelay
                    else { return }

                    try? await Task.sleep(for: retryDelay)
                    guard !Task.isCancelled else { return }
                    AppStoreReviewPrompt.shared.fireIfArmed(requestReview)
                }
        }
    }
#endif
