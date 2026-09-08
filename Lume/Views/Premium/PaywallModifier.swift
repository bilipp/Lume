//
//  PaywallModifier.swift
//  Lume
//
//  Convenience for presenting the paywall from a gate site. Each originating view
//  owns its own `@State` flag and attaches `.paywall(isPresented:highlight:)`, so
//  the sheet always presents above the surface the user is actually on (a single
//  app-wide sheet would sit under pushed/presented screens like Settings).
//

import SwiftUI

extension View {
    func paywall(isPresented: Binding<Bool>, highlight: PremiumFeature? = nil) -> some View {
        // The single central presentation point, so it is also the one place
        // that can tell the review prompt to keep its distance from a paywall
        // the user just closed.
        sheet(
            isPresented: isPresented,
            onDismiss: { AppStoreReviewPrompt.shared.notePaywallDismissed() },
            content: {
                PaywallView(highlight: highlight)
                    // Paired with `onDismiss` above so the review prompt knows
                    // a paywall is on screen, not merely that one has closed.
                    .onAppear { AppStoreReviewPrompt.shared.notePaywallAppeared() }
            }
        )
    }
}
