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

    func testHistoryReopensARelease() {
        let historyLink = app.buttons["All Release Notes"]
        XCTAssertTrue(historyLink.waitForExistence(timeout: 15))
        historyLink.tap()

        let release = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "whatsNew.release.")).firstMatch
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        release.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }
}
