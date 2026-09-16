import XCTest

final class SettingsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    private func openSettings() {
        XCTAssertTrue(app.openSettingsSheet(), "Settings sheet did not open")
    }

    func testSettingsAccessibleFromToolbar() {
        openSettings()
    }

    func testPlaylistsSectionShowsPlaylist() {
        openSettings()
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 10))
    }

    func testPlayerEnginePickerExists() {
        openSettings()
        // The single-engine picker this once asserted ("Engine") is gone: the
        // Player section now links to an ordered engine-priority list — and it
        // sits thirteen sections down, so it has to be scrolled into being.
        let engineLabel = app.staticTexts["Player Engines"]
        XCTAssertTrue(app.scrollUntilExists(engineLabel), "Player Engines row never appeared")
    }

    func testAddPlaylistButtonExists() {
        openSettings()
        let addButton = app.buttons["Add Playlist"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    }

    func testPlaylistDetailNavigation() {
        openSettings()
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 10))
        playlistName.tap()
        XCTAssertTrue(app.navigationBars["Test Playlist"].waitForExistence(timeout: 10))
        let nameLabel = app.staticTexts["Name"]
        XCTAssertTrue(nameLabel.waitForExistence(timeout: 10))
    }
}
