//
//  ScreenOccupancyTests.swift
//  LumeTests
//
//  `ScreenOccupancy`, the one signal every root alert (the rating sheet, the
//  Lume Cloud notices, the pairing sheet) waits on.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct ScreenOccupancyTests {
    @Test func `two concurrent players both have to close before the screen is clear`() {
        let occupancy = ScreenOccupancy()
        #expect(occupancy.playerIsVisible == false)

        occupancy.notePlayerAppeared()
        occupancy.notePlayerAppeared()
        occupancy.notePlayerDisappeared()
        // The second player is still up: a Bool would have said otherwise.
        #expect(occupancy.playerIsVisible)

        occupancy.notePlayerDisappeared()
        #expect(occupancy.playerIsVisible == false)
    }

    @Test func `a presented paywall is not a safe moment`() {
        let occupancy = ScreenOccupancy()
        #expect(occupancy.paywallIsVisible == false)

        occupancy.notePaywallAppeared()
        #expect(occupancy.paywallIsVisible)

        occupancy.notePaywallDismissed()
        #expect(occupancy.paywallIsVisible == false)
    }

    @Test func `an unbalanced close cannot drive a count negative`() {
        let occupancy = ScreenOccupancy()
        occupancy.notePlayerDisappeared()
        occupancy.notePaywallDismissed()
        #expect(occupancy.playerIsVisible == false)
        #expect(occupancy.paywallIsVisible == false)
    }

    @Test func `the screen is busy while anything blocking is up`() {
        let occupancy = ScreenOccupancy()
        let root = UUID()
        #expect(occupancy.isScreenBusy == false)

        occupancy.notePlayerAppeared()
        #expect(occupancy.isScreenBusy)
        occupancy.notePlayerDisappeared()

        occupancy.notePaywallAppeared()
        #expect(occupancy.isScreenBusy)
        occupancy.notePaywallDismissed()

        occupancy.noteBlockingSheetAppeared()
        #expect(occupancy.isScreenBusy)
        occupancy.noteBlockingSheetDismissed()

        occupancy.noteBrowseRootCovered(true, by: root)
        #expect(occupancy.isScreenBusy)
        occupancy.noteBrowseRootCovered(false, by: root)

        #expect(occupancy.isScreenBusy == false)
    }

    @Test func `the screen stays busy until every blocker is gone`() {
        let occupancy = ScreenOccupancy()
        let root = UUID()
        occupancy.noteBrowseRootCovered(true, by: root)
        occupancy.notePlayerAppeared()

        occupancy.noteBrowseRootCovered(false, by: root)
        #expect(occupancy.isScreenBusy)

        occupancy.notePlayerDisappeared()
        #expect(occupancy.isScreenBusy == false)
    }

    /// The add-device sheet is the browse root's own, so it waits on what
    /// covers the root from above — never on its own entry in
    /// `browseRootIsCovered`.
    @Test func `the browse root's own sheet waits only on what covers it from above`() {
        let occupancy = ScreenOccupancy()
        let root = UUID()
        occupancy.noteBrowseRootCovered(true, by: root)
        #expect(occupancy.isScreenBusy)
        #expect(occupancy.coversBrowseRoot == false)

        occupancy.noteBlockingSheetAppeared()
        #expect(occupancy.coversBrowseRoot)
        occupancy.noteBlockingSheetDismissed()

        occupancy.notePaywallAppeared()
        #expect(occupancy.coversBrowseRoot)
        occupancy.notePaywallDismissed()

        occupancy.notePlayerAppeared()
        #expect(occupancy.coversBrowseRoot)
    }

    /// Every window runs its own browse root; one closing its sheet must not
    /// clear another that still has one up.
    @Test func `each window's browse root reports its own cover`() {
        let occupancy = ScreenOccupancy()
        let first = UUID()
        let second = UUID()
        occupancy.noteBrowseRootCovered(true, by: first)
        occupancy.noteBrowseRootCovered(true, by: second)

        occupancy.noteBrowseRootCovered(false, by: first)
        #expect(occupancy.browseRootIsCovered)

        occupancy.noteBrowseRootCovered(false, by: second)
        #expect(occupancy.browseRootIsCovered == false)
    }

    @Test func `only one window raises a root notice at a time`() {
        let occupancy = ScreenOccupancy()
        let first = UUID()
        let second = UUID()
        #expect(occupancy.claimRootNotice(first))
        #expect(occupancy.claimRootNotice(second) == false)
        #expect(occupancy.canRaiseRootNotice(second) == false)

        occupancy.releaseRootNotice(second)
        #expect(occupancy.canRaiseRootNotice(second) == false)

        occupancy.releaseRootNotice(first)
        #expect(occupancy.claimRootNotice(second))
    }
}
