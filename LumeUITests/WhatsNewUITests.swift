import XCTest

/// The What's New sheet, forced on by `-whats-new` (automated runs never show
/// it otherwise), and the release history behind it.
final class WhatsNewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-whats-new"]
        app.launch()
    }

    func testSheetShowsOnceTheBrowseUIIsUpAndContinueDismissesIt() {
        let continueButton = app.buttons["whatsNew.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["What’s New in Lume"].exists)

        continueButton.tap()
        XCTAssertTrue(continueButton.waitForNonExistence(timeout: 5))
    }

    func testSheetOpensTheReleaseHistory() {
        let historyLink = app.buttons["All Release Notes"]
        XCTAssertTrue(historyLink.waitForExistence(timeout: 15))
        historyLink.tap()
        XCTAssertTrue(app.navigationBars["What’s New"].waitForExistence(timeout: 5))
    }
}
