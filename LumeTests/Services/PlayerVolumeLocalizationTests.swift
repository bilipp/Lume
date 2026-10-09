//
//  PlayerVolumeLocalizationTests.swift
//  LumeTests
//
//  Every user-facing literal the macOS player volume control added, asserted
//  present and translated in all nine shipping locales. The control only
//  compiles on macOS, so the catalog is read directly rather than resolved.
//

import Foundation
@testable import Lume
import Testing

@Suite("Player volume localization")
struct PlayerVolumeLocalizationTests {
    /// The speaker button's label and tooltip in both states, and the slider's
    /// accessibility label.
    static let newKeys = [
        "Mute",
        "Unmute",
        "Volume"
    ]

    @Test func `every player volume string is translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.newKeys {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }
}
