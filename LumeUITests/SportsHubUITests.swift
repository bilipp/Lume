import XCTest

/// Sports Hub tab smoke tests. Runs offline under `-ui-testing` (CloudKit off,
/// auto-sync off, a seeded placeholder playlist so the app opens on the tab
/// bar). Asserts the Sports tab renders — the Pro-locked state or the premium
/// hub — that no blocking cover steals the screen, and that the Manage Teams
/// sheet opens and dismisses.
final class SportsHubUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The tab is off by default on iPhone; force it on so the smoke test can reach it.
        app.launchArguments = ["-ui-testing", "-sports.tabEnabled", "YES"]
        app.launch()
    }

    /// Selects the Sports tab, falling back to the iPhone "More" overflow when
    /// the extra tab pushes the bar past its visible limit. In the overflow the
    /// entry can surface as a cell, static text or button, so try each.
    @discardableResult
    private func openSportsTab() -> Bool {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        let sportsTab = app.tabBars.buttons["Sports"]
        if sportsTab.waitForExistence(timeout: 3) {
            sportsTab.tap()
            return true
        }
        let moreTab = app.tabBars.buttons["More"]
        guard moreTab.waitForExistence(timeout: 3) else { return false }
        moreTab.tap()
        let candidates: [XCUIElement] = [
            app.cells["Sports"].firstMatch,
            app.cells.staticTexts["Sports"].firstMatch,
            app.buttons["Sports"].firstMatch,
            app.staticTexts["Sports"].firstMatch
        ]
        // Let the overflow list settle, then tap the first entry that resolves.
        _ = candidates[0].waitForExistence(timeout: 5)
        for candidate in candidates where candidate.exists {
            candidate.tap()
            return true
        }
        return false
    }

    func testSportsTabRenders() {
        XCTAssertTrue(openSportsTab(), "Sports tab not reachable")

        // Either the Pro-locked state ("Unlock Sports Hub") or the premium hub
        // (a "Sports" nav bar, plus onboarding / Manage Teams) must appear —
        // never a blank screen.
        let unlock = app.buttons["Unlock Sports Hub"]
        let manage = app.buttons["Manage Teams"].firstMatch
        let navBar = app.navigationBars["Sports"]
        let rendered = unlock.waitForExistence(timeout: 5)
            || manage.waitForExistence(timeout: 5)
            || navBar.waitForExistence(timeout: 5)
        XCTAssertTrue(rendered, "Sports tab showed neither the locked nor the hub state")
    }

    func testNoBlockingCoverAppears() {
        XCTAssertTrue(openSportsTab())

        // Auto-sync is disabled under `-ui-testing`, so the full-screen sync
        // cover must never present over the hub.
        let syncCover = app.staticTexts["Syncing your playlist"]
        XCTAssertFalse(syncCover.waitForExistence(timeout: 3), "A blocking sync cover appeared over Sports")

        // The tab bar stays interactive — no modal owns the screen.
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "Tab bar is not interactive on Sports")
    }

    func testManageTeamsSheetOpensAndDismisses() throws {
        XCTAssertTrue(openSportsTab())

        // Manage Teams is only reachable on the premium hub (toolbar button or
        // onboarding card). On the free-tier locked state the paywall stands in
        // for it, so skip rather than fail.
        let manage = app.buttons["Manage Teams"].firstMatch
        try XCTSkipUnless(
            manage.waitForExistence(timeout: 5),
            "Sports Hub is Pro-locked; Manage Teams is unavailable"
        )
        manage.tap()

        let sheetNav = app.navigationBars["Manage Teams"]
        XCTAssertTrue(sheetNav.waitForExistence(timeout: 5), "Manage Teams sheet did not open")

        // The sheet's confirmation action dismisses it (Done, not a swipe — a
        // swipe can be swallowed by the reorder list).
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Manage Teams has no Done button")
        done.tap()
        XCTAssertTrue(sheetNav.waitForNonExistence(timeout: 5), "Manage Teams sheet did not dismiss")
    }
}
