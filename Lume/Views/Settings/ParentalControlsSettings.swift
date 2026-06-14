//
//  ParentalControlsSettings.swift
//  Lume
//
//  The PIN-management surface: set, change or turn off the parental-control PIN.
//  Changing or removing the PIN requires entering the current one, so a child
//  can't disable the gate from Settings (only Content Management is fully
//  locked; the rest of Settings stays reachable). The iOS/macOS Settings section
//  and the tvOS Profiles pane both drive `ParentalPINFlowView`.
//

import SwiftUI

/// Which PIN operation a flow performs. Identifiable so it can drive a sheet.
enum ParentalPINFlow: String, Identifiable {
    case set, change, remove

    var id: String {
        rawValue
    }
}

/// Runs a single PIN operation to completion, then calls `onFinish` (which the
/// presenter uses to dismiss). Reads `ParentalControls` from the environment.
struct ParentalPINFlowView: View {
    let flow: ParentalPINFlow
    let onFinish: () -> Void

    @Environment(ParentalControls.self) private var parental: ParentalControls?

    var body: some View {
        switch flow {
        case .set:
            PINCreateView(
                onComplete: { parental?.setPIN($0); onFinish() },
                onCancel: onFinish
            )
        case .change:
            ChangePINFlow(
                onComplete: { parental?.setPIN($0); onFinish() },
                onCancel: onFinish
            )
        case .remove:
            PINUnlockView(
                title: "Turn Off PIN",
                subtitle: "Enter your current PIN to turn it off.",
                onUnlock: { parental?.disablePIN(); onFinish() },
                onCancel: onFinish
            )
        }
    }
}

#if !os(tvOS)

    extension SettingsView {
        /// The iOS/macOS Settings section for the parental-control PIN.
        var parentalControlsSection: some View {
            ParentalControlsSettingsSection()
        }
    }

    /// Set / change / turn-off PIN rows, presenting the matching flow in a sheet.
    struct ParentalControlsSettingsSection: View {
        @Environment(ParentalControls.self) private var parental: ParentalControls?
        @State private var flow: ParentalPINFlow?

        var body: some View {
            Section {
                if parental?.isPINSet == true {
                    Button {
                        flow = .change
                    } label: {
                        Label("Change PIN", systemImage: "lock.rotation")
                    }
                    Button(role: .destructive) {
                        flow = .remove
                    } label: {
                        Label("Turn Off PIN", systemImage: "lock.open")
                    }
                } else {
                    Button {
                        flow = .set
                    } label: {
                        Label("Set a PIN", systemImage: "lock")
                    }
                }
            } header: {
                Text("Parental Controls")
            } footer: {
                Text("A PIN is required to switch away from a child profile and to open Content Management. Mark a profile as a child profile in Profiles.")
            }
            .sheet(item: $flow) { flow in
                NavigationStack {
                    ParentalPINFlowView(flow: flow) { self.flow = nil }
                        .platformNavigationTitle("Parental Controls")
                }
                #if os(macOS)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 460, idealHeight: 520)
                #endif
            }
        }
    }

#endif
