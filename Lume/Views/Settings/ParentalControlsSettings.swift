//
//  ParentalControlsSettings.swift
//  Lume
//
//  The PIN-management flow: set, change or turn off the parental-control PIN.
//  Changing or removing the PIN requires entering the current one, so a child
//  can't disable the gate (only Content Management is fully locked; the rest of
//  Settings stays reachable). Lives in profile management — `ManageProfilesView`
//  (iOS/macOS) and the tvOS Profiles pane both drive `ParentalPINFlowView`.
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
