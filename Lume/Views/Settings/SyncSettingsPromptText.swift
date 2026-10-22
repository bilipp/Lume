import SwiftUI

/// Titles and messages of the Sync confirmations, shared with the tvOS pane.
enum SyncSettingsPromptText {
    static let privacyNote: LocalizedStringKey = "End-to-end encrypted · Stored in the EU"

    static func name(of backend: SyncBackendSelection) -> LocalizedStringKey {
        switch backend {
        case .icloud: "iCloud"
        case .lumecloud: "Lume Cloud"
        case .off: "Off"
        }
    }

    static func title(_ prompt: SyncSettingsModel.Prompt) -> Text {
        switch prompt {
        case .switchTo(.icloud): Text("Switch to iCloud?")
        case .switchTo(.lumecloud): Text("Switch to Lume Cloud?")
        case .switchTo(.off): Text("Turn Off Sync?")
        case .setUpLumeCloud: Text("Set Up Lume Cloud")
        case .leave: Text("Leave Lume Cloud?")
        case .deleteAccount: Text("Delete Lume Cloud Account?")
        }
    }

    static func message(_ prompt: SyncSettingsModel.Prompt, leaveTarget: SyncBackendSelection) -> Text {
        switch prompt {
        case .switchTo(.icloud):
            Text("Your profiles, playlists and viewing on this device are merged with what’s in iCloud. Nothing is deleted.")
        case .switchTo(.lumecloud):
            Text("Your profiles, playlists and viewing on this device are merged with your Lume Cloud account. Nothing is deleted.")
        case .switchTo(.off):
            Text("Changes stay on this device until you turn sync back on. Nothing is deleted.")
        case .setUpLumeCloud:
            Text(SyncSettingsPromptText.privacyNote)
        case let .leave(otherDeviceNames):
            Text(verbatim: leaveMessage(otherDeviceNames: otherDeviceNames, leaveTarget: leaveTarget))
        case .deleteAccount:
            Text("Your synced data is deleted from Lume Cloud for good, for every device on this account, including Android devices. What’s on this device stays.")
        }
    }

    private static func leaveMessage(otherDeviceNames: [String], leaveTarget: SyncBackendSelection) -> String {
        let base = leaveTarget == .icloud
            ? String(localized: "Your Apple devices go back to iCloud. Your Lume Cloud account and its data stay, so you can rejoin later.")
            : String(localized: "This device stops syncing. Your Lume Cloud account and its data stay, so you can rejoin later.")
        guard !otherDeviceNames.isEmpty else { return base }
        let names = otherDeviceNames.formatted(.list(type: .and))
        let devices = String(localized: "These devices keep using Lume Cloud but stop syncing with this device: \(names)")
        return base + "\n\n" + devices
    }
}
