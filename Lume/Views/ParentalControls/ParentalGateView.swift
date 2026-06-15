//
//  ParentalGateView.swift
//  Lume
//
//  Wraps a screen that must be unlocked with the parental-control PIN before it
//  is shown (Content Management). When no PIN is set the content shows straight
//  through; otherwise the PIN pad is shown until the correct PIN is entered, for
//  the lifetime of this presentation.
//
//  Also provides `pinPrompt`, the modifier the profile switchers use to require
//  the PIN before leaving a child profile.
//

import SwiftUI

struct ParentalGateView<Content: View>: View {
    var subtitle: LocalizedStringKey = "Enter your PIN to manage content."
    @ViewBuilder let content: () -> Content

    @Environment(ParentalControls.self) private var parental: ParentalControls?
    @State private var unlocked = false

    var body: some View {
        if unlocked || !(parental?.restrictedSurfacesLocked ?? false) {
            content()
        } else {
            PINUnlockView(
                title: "Enter PIN",
                subtitle: subtitle,
                onUnlock: { unlocked = true }
            )
        }
    }
}

extension View {
    /// Presents the PIN pad when `target` is set, switching to that profile only
    /// once the correct PIN is entered. Used by the profile switchers to gate
    /// leaving a child profile. Cancelling clears `target` and stays put.
    func pinPrompt(target: Binding<UserProfile?>, onVerified: @escaping (UserProfile) -> Void) -> some View {
        modifier(PINPromptModifier(target: target, onVerified: onVerified))
    }
}

private struct PINPromptModifier: ViewModifier {
    @Binding var target: UserProfile?
    let onVerified: (UserProfile) -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
            content.fullScreenCover(item: $target, content: prompt)
        #else
            content.sheet(item: $target, content: prompt)
        #endif
    }

    private func prompt(_ profile: UserProfile) -> some View {
        PINUnlockView(
            title: "Enter PIN",
            subtitle: "Enter your PIN to switch profile.",
            onUnlock: {
                target = nil
                onVerified(profile)
            },
            onCancel: { target = nil }
        )
    }
}
