//
//  PrimaryPlayButton.swift
//  Lume
//

import SwiftUI

/// The big, full-width primary action (Play / Resume).
///
/// Renders as a high-contrast filled pill: a white button with black text in
/// dark mode, inverting to a black button with white text in light mode so it
/// never disappears against the detail view's `.systemBackground`.
struct PrimaryPlayButton: View {
    let title: LocalizedStringKey
    var systemImage: String = "play.fill"
    var isEnabled: Bool = true
    /// Runs on a long press (a secondary click on macOS); nil leaves a hold
    /// doing nothing extra.
    var chooseSource: (() -> Void)?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var holdTookPress = false

    var body: some View {
        Button {
            if holdTookPress {
                holdTookPress = false
                return
            }
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(colorScheme == .dark ? .white : .black)
        .controlSize(.large)
        .chooseSourceOnHold(chooseSource, holdTookPress: $holdTookPress)
        .disabled(!isEnabled)
    }
}

private extension View {
    /// Always attached, whether or not `chooseSource` is set, so the button
    /// keeps its identity when sources resolve. A Button still fires on the
    /// release that ends a recognized hold, so the hold marks the press as
    /// taken; every new press clears that mark first.
    func chooseSourceOnHold(_ chooseSource: (() -> Void)?, holdTookPress: Binding<Bool>) -> some View {
        #if os(macOS)
            contextMenu {
                if let chooseSource {
                    Button("Choose Source…", systemImage: "square.stack", action: chooseSource)
                }
            }
        #else
            simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onChanged { _ in holdTookPress.wrappedValue = false }
                    .onEnded { _ in
                        guard let chooseSource else { return }
                        holdTookPress.wrappedValue = true
                        chooseSource()
                    }
            )
            .accessibilityActions {
                if let chooseSource {
                    Button("Choose Source…", action: chooseSource)
                }
            }
        #endif
    }
}

#Preview("PrimaryPlayButton - Enabled") {
    PrimaryPlayButton(title: "Play", action: {})
        .padding()
}

#Preview("PrimaryPlayButton - Disabled") {
    PrimaryPlayButton(title: "Play", isEnabled: false, action: {})
        .padding()
}

#Preview("PrimaryPlayButton - Resume") {
    PrimaryPlayButton(title: "Resume", systemImage: "play.fill", action: {})
        .padding()
}
