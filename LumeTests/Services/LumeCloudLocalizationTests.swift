//
//  LumeCloudLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the Lume Cloud sync backend added, asserted
//  present and translated in every shipping locale, with the product name
//  kept in Latin script.
//

import Foundation
@testable import Lume
import Testing

@Suite("Lume Cloud localization")
struct LumeCloudLocalizationTests {
    /// Settings ▸ Sync on every platform: the backend choice, the Lume Cloud
    /// rows and the confirmations behind them.
    static let settingsKeys = [
        "Lume Cloud",
        "Sync With",
        "Not Set Up",
        "Working…",
        "Switch",
        "Switch to iCloud?",
        "Switch to Lume Cloud?",
        "Turn Off Sync",
        "Turn Off Sync?",
        "Set Up Lume Cloud",
        "Create New Account",
        "Join with a Code",
        "Restore from Recovery Key",
        "Leave Lume Cloud",
        "Leave Lume Cloud?",
        "Delete Account",
        "Delete Lume Cloud Account",
        "Delete Lume Cloud Account?",
        "Device Name",
        "Devices",
        "Recovery Key",
        "Recovery key not viewed",
        "End-to-end encrypted",
        "Enter your PIN to change sync settings.",
        "Enter your PIN to add a device to Lume Cloud.",
        "Your profiles, playlists and viewing on this device are merged with what’s in iCloud. Nothing is deleted.",
        "Your profiles, playlists and viewing on this device are merged with your Lume Cloud account. Nothing is deleted.",
        "Changes stay on this device until you turn sync back on. Nothing is deleted.",
        "This device stops syncing. Your Lume Cloud account and its data stay, so you can rejoin later.",
        "These devices keep using Lume Cloud but stop syncing with this device: %@",
        "Your synced data is deleted from Lume Cloud for good, for every device on this account, including Android devices. What’s on this device stays.",
        "Couldn’t Create Account",
        "Couldn’t Delete Account",
        "Couldn’t Leave Lume Cloud",
        "Couldn’t Rename This Device",
        "Couldn’t Switch Sync"
    ]

    /// Joining with a code and adding a device, on the sheet (iOS, macOS,
    /// visionOS) and the drill-in steps (tvOS).
    static let pairingKeys = [
        "Join Lume Cloud",
        "Add a Device",
        "Add “%@”?",
        "New Device",
        "Next",
        "Platform",
        "Pairing QR code",
        "Waiting for the other device…",
        "Enter the 6-digit code shown on the new device.",
        "On a device that already uses Lume Cloud, open Settings ▸ Sync ▸ Add a Device and enter this code, or scan the QR code with that device’s camera.",
        "Only add devices you own. The new device can read everything you sync with Lume Cloud."
    ]

    /// The device list and its remove confirmation.
    static let deviceKeys = [
        "This Device",
        "Other device",
        "Last seen %@",
        "Removed",
        "It stops syncing with Lume Cloud. Anything already on it stays there.",
        "To remove this device, leave Lume Cloud instead."
    ]

    /// Showing, saving and restoring the recovery key, including the tvOS
    /// "visible on your TV" confirmation.
    static let recoveryKeyKeys = [
        "I’ve saved it",
        "Later",
        "Copy",
        "Copied",
        "Share",
        "Show",
        "Show Recovery Key",
        "Show Recovery Key?",
        "Recovery key QR code",
        "This will be visible on your TV. Make sure no one else can see the screen.",
        "If you lose all your devices, this key is the only way back to your Lume Cloud data. Without it, your synced data is gone.",
        "Store it somewhere safe, like a password manager. Never share it.",
        "You can find this key later in Settings ▸ Sync.",
        "Enter the recovery key you saved when you created your Lume Cloud account."
    ]

    /// The status line, the terminal-error notices, the one-time handoff
    /// alert and the account-end alert.
    static let statusKeys = [
        "Busy",
        "Offline",
        "Storage Full",
        "Account Deleted",
        "Uploading %lld of %lld",
        "Sync is off. Changes stay on this device.",
        "Lume Cloud is busy. Sync will retry automatically.",
        "Lume Cloud storage is full. New changes stay on this device.",
        "Lume Cloud can’t be reached. Sync resumes automatically.",
        "This device was removed from Lume Cloud. Your data stays on this device.",
        "Your Lume Cloud account was deleted. Your data stays on this device.",
        "Your Apple devices go back to iCloud. Your Lume Cloud account and its data stay, so you can rejoin later.",
        "Checking Lume Cloud for your playlists…",
        "Sync moved to Lume Cloud",
        "Update Lume on your other devices so they keep syncing.",
        "This device was removed from Lume Cloud. Sync is off; your data stays on this device.",
        "Your Lume Cloud account was deleted. Your Apple devices are back on iCloud; your data stays on this device.",
        "Your Lume Cloud account was deleted. Sync is off; your data stays on this device.",
        "Each profile keeps its own watch history, progress and favorites. Profiles sync across your devices via Lume Cloud.",
        "Each profile keeps its own watch history, progress and favorites. Sync is off, so profiles stay on this device."
    ]

    /// `LumeCloudErrorDescription`'s sentences.
    static let errorKeys = [
        "An item is too large for Lume Cloud and stays on this device.",
        "Another device already answered this pairing code.",
        "Lume Cloud can’t be reached right now. Try again in a moment.",
        "Lume Cloud didn’t accept this device’s sign-in.",
        "Lume Cloud is busy. Try again in a moment.",
        "Lume Cloud is syncing everything again. This happens automatically.",
        "Lume Cloud isn’t available right now.",
        "Lume Cloud isn’t set up on this device.",
        "Lume Cloud ran into a problem. Sync will retry automatically.",
        "Lume Cloud rejected a request. Export a diagnostic report for details.",
        "Lume Cloud sent a response this version of Lume can’t read. Update Lume to resume syncing.",
        "Lume couldn’t save the Lume Cloud key on this device. Unlock the device and try again.",
        "Pairing didn’t finish. Start again on the new device.",
        "That device uses a different Lume Cloud server.",
        "That isn’t a recovery key.",
        "The pairing code is wrong or has expired.",
        "The recovery key has a typo. Check it and try again.",
        "This Lume Cloud server isn’t accepting new accounts.",
        "This account already exists. Join with a code or your recovery key instead.",
        "This device already syncs with Lume Cloud.",
        "This recovery key doesn’t belong to a Lume Cloud account.",
        "Turn on Lume Cloud on this device first."
    ]

    static var allKeys: [String] {
        settingsKeys + pairingKeys + deviceKeys + recoveryKeyKeys + statusKeys + errorKeys
    }

    @Test func `every Lume Cloud string is translated in every shipping locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `every Lume Cloud string resolves to a non empty value`() {
        for key in Self.allKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    /// The product name is never transliterated, in any script.
    @Test func `every translation keeps Lume Cloud in Latin script`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys where key.contains("Lume Cloud") {
            let translations = try #require(catalog.localizations(for: key), "\(key) is not in the string catalog")
            for (locale, value) in translations {
                #expect(value.contains("Lume Cloud"), "\(locale) drops “Lume Cloud” from \(key)")
            }
        }
    }
}
