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
        sheet(isPresented: isPresented) {
            PaywallView(highlight: highlight)
        }
    }
}
