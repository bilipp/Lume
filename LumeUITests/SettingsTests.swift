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

    /// Dragging an engine in Player › Engines changes the order, and the new
    /// order is still there after leaving the screen and coming back.
    func testReorderingPlayerEnginesSticks() {
        openSettings()
        let playerRow = app.buttons["Player"].firstMatch
        XCTAssertTrue(app.scrollUntilExists(playerRow), "Player row never appeared")
        playerRow.tap()
        let enginesRow = app.buttons["Engines"].firstMatch
        XCTAssertTrue(app.scrollUntilExists(enginesRow), "Engines row never appeared")
        enginesRow.tap()
        XCTAssertTrue(app.staticTexts["Primary"].waitForExistence(timeout: 10), "Engine priority list never appeared")

        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder"))
        XCTAssertGreaterThanOrEqual(handles.count, 2, "No drag handles: \(app.debugDescription)")
        let first = handles.element(boundBy: 0)
        let third = handles.element(boundBy: 2)
        let firstLabel = first.label
        first.press(forDuration: 0.6, thenDragTo: third)

        let moved = handles.element(boundBy: 0).label
        XCTAssertNotEqual(moved, firstLabel, "The dragged engine snapped back to the top")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(enginesRow.waitForExistence(timeout: 10))
        enginesRow.tap()
        XCTAssertTrue(app.staticTexts["Primary"].waitForExistence(timeout: 10))
        XCTAssertEqual(handles.element(boundBy: 0).label, moved, "The new order was lost after leaving the screen")
    }

    /// Settings › Sync lists every backend. `-ui-testing` keeps Lume Cloud inert,
    /// so nothing here reaches the network; the test only looks, never switches.
    func testSyncSettingsOffersEveryBackend() {
        openSettings()
        // Scoped to the list: the library toolbar behind the sheet has a Sync button too.
        let syncRow = app.collectionViews.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Sync"))
            .firstMatch
        XCTAssertTrue(app.scrollUntilExists(syncRow), "Sync row never appeared")
        syncRow.tap()
        XCTAssertTrue(app.navigationBars["Sync"].waitForExistence(timeout: 10), "Settings › Sync did not open")
        for choice in ["iCloud", "Lume Cloud", "Off"] {
            XCTAssertTrue(
                app.collectionViews.buttons[choice].waitForExistence(timeout: 10),
                "Sync choice \(choice) is missing"
            )
        }
    }

    func testAddPlaylistButtonExists() {
        XCTAssertTrue(app.openSettingsPlaylists(), "Settings › Playlists did not open")
        let addButton = app.buttons["Add Playlist"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    }

    func testHidingLiveTVInLibraryRemovesTheTab() {
        XCTAssertTrue(app.tabBars.buttons["Live TV"].waitForExistence(timeout: 60))
        openTabSettings()

        let liveTVSwitch = app.switches["Live TV"].firstMatch
        XCTAssertTrue(liveTVSwitch.waitForExistence(timeout: 10))
        toggle(liveTVSwitch)
        XCTAssertEqual(liveTVSwitch.value as? String, "0")

        dismissTabSettings()

        XCTAssertTrue(app.tabBars.buttons["Movies"].exists)
        XCTAssertFalse(app.tabBars.buttons["Live TV"].exists)
    }

    func testHidingHomeRemovesTheTab() {
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 60))
        openTabSettings()

        let homeSwitch = app.switches["Home"].firstMatch
        XCTAssertTrue(homeSwitch.waitForExistence(timeout: 10))
        toggle(homeSwitch)

        // Settings was opened from Home's toolbar; the tab bar waits for the
        // sheet to close before it drops Home.
        XCTAssertTrue(app.navigationBars["Tabs"].exists, "Hiding Home dismissed Settings")
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        dismissTabSettings()

        let moviesTab = app.tabBars.buttons["Movies"]
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForNonExistence(timeout: 5), "Home stayed in the tab bar")
        XCTAssertTrue(waitForSelection(of: moviesTab), "Movies was not selected once Home was hidden")
    }

    /// With no Movies, Series or Live TV tab left, Home is the way back to
    /// Settings, so its switch stays on and can't be turned off.
    func testHomeStaysWhenNoContentTabIsShown() {
        XCTAssertTrue(app.tabBars.buttons["Live TV"].waitForExistence(timeout: 60))
        openTabSettings()

        let homeSwitch = app.switches["Home"].firstMatch
        XCTAssertTrue(homeSwitch.waitForExistence(timeout: 10))
        XCTAssertTrue(homeSwitch.isEnabled)

        for title in ["Movies", "Series", "Live TV"] {
            let contentSwitch = app.switches[title].firstMatch
            XCTAssertTrue(contentSwitch.waitForExistence(timeout: 10), "\(title) switch is missing")
            toggle(contentSwitch)
            XCTAssertEqual(contentSwitch.value as? String, "0", "\(title) did not turn off")
        }

        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: homeSwitch)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed, "Home switch is still enabled")
        XCTAssertEqual(homeSwitch.value as? String, "1")
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

    /// Settings › Library › Tabs.
    private func openTabSettings() {
        openSettings()
        let libraryRow = app.buttons["Library"].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 10))
        libraryRow.tap()
        let tabsRow = app.collectionViews.buttons["Tabs"].firstMatch
        XCTAssertTrue(tabsRow.waitForExistence(timeout: 10), "Library › Tabs row is missing")
        tabsRow.tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForExistence(timeout: 10), "Library › Tabs did not open")
    }

    /// Taps the switch control itself. The row's switch element spans the
    /// whole cell, whose trailing edge is the tab's drag handle.
    private func toggle(_ element: XCUIElement) {
        let control = element.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    /// iOS Settings is a sheet with no Done button; drag it closed.
    private func dismissTabSettings() {
        let nav = app.navigationBars["Tabs"]
        nav.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        XCTAssertTrue(nav.waitForNonExistence(timeout: 10), "Settings sheet did not dismiss")
    }

    private func waitForSelection(of tab: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab)
        return XCTWaiter.wait(for: [selected], timeout: timeout) == .completed
    }
}
