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
        XCTAssertTrue(app.openSettingsPlaylists(), "Settings › Playlists did not open")
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 10))
    }

    func testPlayerEnginePickerExists() {
        openSettings()
        // The engine-priority list sits behind Player › Advanced › Engines.
        let playerRow = app.buttons["Player"].firstMatch
        XCTAssertTrue(app.scrollUntilExists(playerRow), "Player row never appeared")
        playerRow.tap()
        let enginesRow = app.buttons["Engines"].firstMatch
        XCTAssertTrue(app.scrollUntilExists(enginesRow), "Engines row never appeared")
        enginesRow.tap()
        XCTAssertTrue(app.staticTexts["Primary"].waitForExistence(timeout: 10), "Engine priority list never appeared")
    }

    func testAddPlaylistButtonExists() {
        XCTAssertTrue(app.openSettingsPlaylists(), "Settings › Playlists did not open")
        let addButton = app.buttons["Add Playlist"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    }

    func testHidingLiveTVInLibraryRemovesTheTab() {
        XCTAssertTrue(app.tabBars.buttons["Live TV"].waitForExistence(timeout: 60))
        openSettings()
        let libraryRow = app.buttons["Library"].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 10))
        libraryRow.tap()

        let liveTVSwitch = app.switches["Live TV"].firstMatch
        XCTAssertTrue(liveTVSwitch.waitForExistence(timeout: 10))
        // The switch's own knob sits at the trailing edge of the row.
        liveTVSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(liveTVSwitch.value as? String, "0")

        // iOS Settings is a sheet with no Done button; drag it closed.
        let nav = app.navigationBars["Library"]
        nav.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        XCTAssertTrue(nav.waitForNonExistence(timeout: 10), "Settings sheet did not dismiss")

        XCTAssertTrue(app.tabBars.buttons["Movies"].exists)
        XCTAssertFalse(app.tabBars.buttons["Live TV"].exists)
    }

    func testPlaylistDetailNavigation() {
        XCTAssertTrue(app.openSettingsPlaylists(), "Settings › Playlists did not open")
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 10))
        playlistName.tap()
        XCTAssertTrue(app.navigationBars["Test Playlist"].waitForExistence(timeout: 10))
        let nameLabel = app.staticTexts["Name"]
        XCTAssertTrue(nameLabel.waitForExistence(timeout: 10))
    }
}
