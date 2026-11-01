//
//  SiriIntentDrain.swift
//  Lume
//
//  Runs the request a Siri intent left in `IntentRouter` once the browse root
//  is free to act on it. A modifier rather than `MainTabView` state, so the
//  occupancy and premium reads it re-runs on don't re-render the tab root.
//

import SwiftData
import SwiftUI

extension View {
    /// Drains `IntentRouter.shared` when nothing it can't land over is on
    /// screen. `rootIsCovered` is the browse root's own presentations plus a
    /// profile roster that isn't resolved yet; `route` plays or opens the
    /// link, re-resolving it for the profile now active. A stream asked for
    /// while a player is up is swapped into that player instead, resolved
    /// under `restriction`.
    func drainsSiriIntents(
        router: DeepLinkRouter,
        rootIsCovered: Bool,
        restriction: ContentRestriction,
        route: @escaping (DeepLink) -> Void
    ) -> some View {
        modifier(SiriIntentDrain(router: router, rootIsCovered: rootIsCovered, restriction: restriction, route: route))
    }

    /// Runs `resume` once the automatic sync `SiriLaunchSyncDeferral` held
    /// for a cold-launch Siri stream may go: its player closed, or the request
    /// ended without one coming up.
    func resumesSyncAfterSiriPlayback(_ resume: @escaping () -> Void) -> some View {
        modifier(SiriLaunchSyncResume(resume: resume))
    }
}

private struct SiriLaunchSyncResume: ViewModifier {
    let resume: () -> Void

    /// How long a consumed request gets to bring its player up before the
    /// deferral treats it as one that won't play (not found for this profile,
    /// opened a detail page instead).
    private static let playerGrace: Duration = .seconds(3)

    private struct State: Equatable {
        let phase: SiriLaunchSyncDeferral.Phase
        let requestPending: Bool
        let playerIsVisible: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: currentState) {
                await advance(from: currentState)
            }
    }

    private var currentState: State {
        State(
            phase: SiriLaunchSyncDeferral.shared.phase,
            requestPending: IntentRouter.shared.hasPending,
            playerIsVisible: ScreenOccupancy.shared.playerIsVisible
        )
    }

    private func advance(from state: State) async {
        guard state.phase != .none else { return }
        if state.phase == .awaitingPlayback, !state.requestPending, !state.playerIsVisible {
            try? await Task.sleep(for: Self.playerGrace)
            guard !Task.isCancelled else { return }
        }
        let deferral = SiriLaunchSyncDeferral.shared
        if deferral.update(
            requestPending: IntentRouter.shared.hasPending,
            playerIsVisible: ScreenOccupancy.shared.playerIsVisible
        ) {
            resume()
        }
    }
}

private struct SiriIntentDrain: ViewModifier {
    let router: DeepLinkRouter
    let rootIsCovered: Bool
    let restriction: ContentRestriction
    let route: (DeepLink) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsPaywall = false
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif

    /// Long enough for a cover or sheet that just closed to finish its
    /// transition; one presented mid-dismissal is dropped without a word.
    private static let settle: Duration = .milliseconds(500)

    private struct Attempt: Equatable {
        let pending: PendingIntent?
        let isBlocked: Bool
        let playerCoversRoot: Bool
        let isPremium: Bool
    }

    /// Waiting until the scene is in front keeps a request queued for a
    /// backgrounded app withdrawable if its foreground request is refused.
    private var isBlocked: Bool {
        scenePhase != .active
            || rootIsCovered
            || ScreenOccupancy.shared.paywallIsVisible
            || ScreenOccupancy.shared.blockingSheetIsVisible
    }

    /// A player over the browse root, Multi-View included. On macOS players
    /// open in their own window and leave the root free.
    private var playerCoversRoot: Bool {
        #if os(macOS)
            false
        #else
            ScreenOccupancy.shared.playerIsVisible
        #endif
    }

    /// A single player is up that takes the request in place. Multi-View has
    /// no one stream to swap, and without Pro the request waits for the player
    /// to close so the paywall can show over the browse root.
    private var playerTakesSwap: Bool {
        playerCoversRoot
            && PremiumManager.shared.isPremium
            && NowPlayingService.shared.currentMedia != nil
    }

    private var playerAllowsDrain: Bool {
        !playerCoversRoot || playerTakesSwap
    }

    func body(content: Content) -> some View {
        content
            .task(id: Attempt(
                pending: IntentRouter.shared.pending,
                isBlocked: isBlocked,
                playerCoversRoot: playerCoversRoot,
                isPremium: PremiumManager.shared.isPremium
            )) {
                await drain()
            }
            .paywall(isPresented: $showsPaywall, highlight: .siri)
            .onChange(of: showsPaywall) { _, isShown in
                if !isShown {
                    IntentRouter.shared.paywallDismissed()
                }
            }
    }

    private func drain() async {
        guard IntentRouter.shared.hasPending, !isBlocked else { return }
        router.closeOverlaysForIntent()
        #if os(macOS)
            dismissWindow(id: "multiview")
        #endif
        // Closing Multi-View drops the player count, which re-runs this.
        guard playerAllowsDrain else { return }
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled else { return }
        let screenIsClear = !isBlocked && playerAllowsDrain
        guard let waiting = IntentRouter.shared.pending else { return }
        let decision = SiriSwapDecision(
            for: waiting.link,
            target: playerTakesSwap
                ? WidgetLinkResolver.resolve(waiting.link, in: modelContext, restriction: restriction)
                : nil,
            playerTakesSwap: playerTakesSwap
        )
        guard decision != .waitForPlayerToClose else { return }
        switch IntentRouter.shared.consumePending(screenIsClear: screenIsClear) {
        case let .play(request):
            guard resumeIsAllowed(request.link) else { return }
            apply(decision, to: request.link)
        case .showPaywall:
            showsPaywall = true
        case nil:
            break
        }
    }

    /// A `.resume` reopens the last stream played on this device by anyone,
    /// so it's re-checked for the profile active now; refused, it does nothing.
    private func resumeIsAllowed(_ link: DeepLink) -> Bool {
        link != .resume || ResumeSnapshotCheck.canResume(in: modelContext, restriction: restriction)
    }

    /// Hands a stream to the player already up instead of presenting a second
    /// one over it. macOS gets the same from `MacPlayerWindowRouter`.
    private func apply(_ decision: SiriSwapDecision, to link: DeepLink) {
        switch decision {
        case .route:
            route(link)
        case let .swap(media):
            if !ExternalPlayback.open(media) {
                PlayerSwapRequests.shared.request(media)
            }
        case .keepPlayer, .waitForPlayerToClose:
            break
        }
    }
}

/// What a Siri request does while a single player is up. Anything the player
/// can't take in place stays queued and routes once the player closes.
enum SiriSwapDecision: Equatable {
    /// No player takes it: route the link over the browse root.
    case route
    case swap(PlayableMedia)
    /// A `.resume` with a player up only brings that player forward.
    case keepPlayer
    case waitForPlayerToClose

    init(for link: DeepLink, target: WidgetLinkResolver.Target?, playerTakesSwap: Bool) {
        guard playerTakesSwap else {
            self = .route
            return
        }
        if case let .play(media) = target {
            self = .swap(media)
        } else if link == .resume {
            self = .keepPlayer
        } else {
            self = .waitForPlayerToClose
        }
    }
}
