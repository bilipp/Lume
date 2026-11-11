//
//  VODSourceFailureHandoffTests.swift
//  LumeTests
//
//  A source that failed on every engine goes back to the detail screen that
//  opened it, and only to a screen that offers that source.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct VODSourceFailureHandoffTests {
    @Test func `a failure nobody asked for keeps the player's own error`() {
        let handoff = VODSourceFailureHandoff()
        #expect(!handoff.handsOff(mediaID: "m"))
        #expect(!handoff.report(mediaID: "m"))
        #expect(handoff.pending == nil)
    }

    @Test func `an expected failure is taken once by the screen offering the source`() throws {
        let handoff = VODSourceFailureHandoff()
        handoff.expect(mediaID: "episode-1", sourceRowID: "series-a")
        #expect(handoff.handsOff(mediaID: "episode-1"))
        #expect(handoff.report(mediaID: "episode-1"))
        #expect(!handoff.handsOff(mediaID: "episode-1"))

        #expect(handoff.take(ifAmong: ["series-b"]) == nil)
        let failure = try #require(handoff.take(ifAmong: ["series-a", "series-b"]))
        #expect(failure.sourceRowID == "series-a")
        #expect(handoff.take(ifAmong: ["series-a"]) == nil)
    }

    @Test func `a released or evicted expectation no longer hands off`() {
        let handoff = VODSourceFailureHandoff()
        handoff.expect(mediaID: "m", sourceRowID: "r")
        handoff.release(mediaID: "m")
        #expect(!handoff.handsOff(mediaID: "m"))

        for index in 0 ... 8 {
            handoff.expect(mediaID: "m\(index)", sourceRowID: "r\(index)")
        }
        #expect(!handoff.handsOff(mediaID: "m0"))
        #expect(handoff.handsOff(mediaID: "m8"))
    }

    @Test func `the picker comes back with the failed copy marked and another preselected`() {
        let options = ["a", "b", "c"].map { id in
            VODSourceOption(
                rowID: id, playlistID: .init(), playlistName: id, title: id, qualityLabel: nil,
                isHDR: false, isDolbyVision: false, languageCode: nil, categoryName: nil, isMediaServer: false
            )
        }
        let decision = VODSourceDecision.decide(
            options: options, remembered: "a", chooseBeforePlaying: false, forcePicker: false, failed: ["a"]
        )
        #expect(decision == .showPicker(preselected: options[1]))
    }
}
