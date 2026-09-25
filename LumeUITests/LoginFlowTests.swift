import XCTest

/// Tests the initial state when the app launches with a seeded playlist.
/// The login form is bypassed via the -ui-testing launch argument.
final class LoginFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    func testAppShowsMainTabBarWithSeededData() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testTabBarShowsAllTabs() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Movies"].exists)
        XCTAssertTrue(app.tabBars.buttons["Series"].exists)
        XCTAssertTrue(app.tabBars.buttons["Live TV"].exists)
    }

    func testAddPlaylistButtonAvailableInSettings() {
        XCTAssertTrue(app.openSettingsSheet(), "Settings sheet did not open")
        let addButton = app.buttons["Add Playlist"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    }

    func testSeededPlaylistNameVisible() {
        XCTAssertTrue(app.openSettingsSheet(), "Settings sheet did not open")
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 10))
    }

    func testPlaylistCanBeDeleted() {
        XCTAssertTrue(app.openSettingsSheet(), "Settings sheet did not open")
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 10))
        playlistName.swipeLeft()
        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
    }

    func testServerConnectionNotVisibleWithSeededData() {
        let header = app.staticTexts["Server Connection"]
        XCTAssertFalse(header.waitForExistence(timeout: 2))
    }
}
