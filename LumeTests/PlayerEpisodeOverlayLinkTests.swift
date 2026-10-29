//
//  PlayerEpisodeOverlayLinkTests.swift
//  LumeTests
//
//  Covers `PlayerEpisodeOverlayLink`: the tvOS focus handoff once the controls
//  hide (the tap-catcher only gets focus when no episode button claims it) and
//  the bar height Skip Intro clears, which survives the bar unmounting.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct PlayerEpisodeOverlayLinkTests {
    private func catcherFocused(after link: PlayerEpisodeOverlayLink) async -> Bool {
        var focused = false
        await link.controlsDidHide { focused = true }.value
        return focused
    }

    @Test func `catcher takes focus when no button claims it`() async {
        #expect(await catcherFocused(after: PlayerEpisodeOverlayLink()))
    }

    @Test func `a claiming button keeps focus from the catcher`() async {
        let link = PlayerEpisodeOverlayLink()
        link.claimFocus(.skipIntro, true)
        #expect(await !catcherFocused(after: link))
    }

    @Test func `claim written after the handoff is scheduled still wins`() async {
        // The host schedules its handoff from its own onChange, which may run
        // before the overlay's onChange in the same update.
        let link = PlayerEpisodeOverlayLink()
        var focused = false
        let handoff = link.controlsDidHide { focused = true }
        link.claimFocus(.nextEpisode, true)
        await handoff.value
        #expect(!focused)
    }

    @Test func `releasing every claim hands focus back to the catcher`() async {
        let link = PlayerEpisodeOverlayLink()
        link.claimFocus(.skipIntro, true)
        link.claimFocus(.nextEpisode, true)
        link.claimFocus(.skipIntro, false)
        #expect(await !catcherFocused(after: link))
        link.claimFocus(.nextEpisode, false)
        #expect(await catcherFocused(after: link))
    }

    @Test func `bar height keeps the last measurement`() {
        let link = PlayerEpisodeOverlayLink()
        link.reportControlsBarHeight(132)
        #expect(link.controlsBarHeight == 132)
        // The bar unmounts as the controls hide, reporting the key's default.
        link.reportControlsBarHeight(0)
        #expect(link.controlsBarHeight == 132)
        link.reportControlsBarHeight(148)
        #expect(link.controlsBarHeight == 148)
    }
}
