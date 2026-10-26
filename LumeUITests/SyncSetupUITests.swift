import XCTest

/// The first-run sync choice, forced on by `-sync-setup` (automated runs skip
/// it otherwise). `-ui-testing` keeps CloudKit off and Lume Cloud inert, so
/// nothing reaches the network. The tests commit only iCloud, the default, so
/// later runs launch as before.
final class SyncSetupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-sync-setup"]
        app.launch()
    }

    private func option(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    func testOffersEveryBackendWithICloudSelected() {
        XCTAssertTrue(app.staticTexts["Sync Your Library"].waitForExistence(timeout: 10))
        for name in ["iCloud", "Lume Cloud", "Don’t Sync"] {
            XCTAssertTrue(option(name).exists, "Sync option \(name) is missing")
        }
        XCTAssertTrue(option("iCloud").isSelected)
        XCTAssertFalse(option("Lume Cloud").isSelected)
        XCTAssertTrue(app.buttons["Continue"].exists)
    }

    func testLumeCloudOpensItsAccountStepAndBacksOut() {
        XCTAssertTrue(option("Lume Cloud").waitForExistence(timeout: 10))
        option("Lume Cloud").tap()
        XCTAssertTrue(option("Lume Cloud").isSelected)
        app.buttons["Continue"].tap()

        for name in ["Create New Account", "Join with a Code", "Restore from Recovery Key"] {
            XCTAssertTrue(option(name).waitForExistence(timeout: 10), "Lume Cloud option \(name) is missing")
        }
        // No other Apple device chose Lume Cloud in a UI-test run.
        XCTAssertFalse(option("Use Your Existing Account").exists)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sync Your Library"].waitForExistence(timeout: 10))
    }

    func testContinuingWithICloudOpensTheApp() {
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()

        // `-ui-testing` seeds a playlist, so the app opens instead of the form.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Sync Your Library"].exists)
    }
}
