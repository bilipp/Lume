import XCTest

/// End-to-end m3u flow against a real, free public playlist (iptv-org,
/// ~10k channels): add the playlist through the add form, run the import, then
/// verify Live TV shows synced channels.
///
/// Prerequisites:
///  - Network access (the playlist is fetched from iptv-org.github.io).
///
/// Structured like `StalkerPortalFlowTests` and for the same reason: the app
/// must launch under `-ui-testing`, which disables CloudKit. With CloudKit on,
/// an un-entitled test binary never finishes the initial sync, so the launch
/// gate keeps `CloudSyncLaunchView` up and the add form is never reachable.
/// That also disables auto-sync, so the import is triggered by hand.
final class M3UPlaylistFlowTests: XCTestCase {
    private let playlistURL = "https://iptv-org.github.io/iptv/index.m3u"
    private let playlistName = "iptv-org"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddM3UPlaylistSyncsAndShowsChannels() {
        let app = XCUIApplication()
        launchAndOpenAddForm(app)
        addM3UPlaylist(app)
        dismissSettingsToTabBar(app)
        activateM3UPlaylist(app)
        runManualSync(app)
        assertLiveTVShowsContent(app)
    }

    // MARK: - Steps

    /// Launches the app and opens the add-playlist form.
    private func launchAndOpenAddForm(_ app: XCUIApplication) {
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.openSettingsSheet(), "Settings sheet did not open")
        let addButton = app.buttons["Add Playlist"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
    }

    /// Fills the m3u form and submits it, waiting for the playlist to be accepted.
    private func addM3UPlaylist(_ app: XCUIApplication) {
        // The segment carries the picker's own text ("M3U"); "M3U Playlist" is
        // the section header, which only appears once it is already selected.
        let m3uSegment = app.buttons["M3U"]
        XCTAssertTrue(m3uSegment.waitForExistence(timeout: 10), "No M3U segment.\n\(app.debugDescription)")
        m3uSegment.tap()

        let nameField = app.textFields["e.g. My IPTV"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(playlistName)

        let urlField = app.textFields["e.g. http://example.com/playlist.m3u"]
        urlField.tap()
        urlField.typeText(playlistURL)

        // An explicit (404ing) guide URL keeps the test deterministic: EPG
        // failures are non-fatal by design, while the playlist's own header
        // points at a multi-hundred-megabyte guide on a slow third-party host.
        // Trailing newline dismisses the keyboard — it otherwise covers the
        // submit button, and XCUITest taps don't scroll covered elements into view.
        let epgField = app.textFields["EPG URL (optional)"]
        epgField.tap()
        epgField.typeText("https://iptv-org.github.io/iptv/no-such-guide.xml\n")

        // More than one element can carry the "Add Playlist" label (navigation
        // title vs. submit button), so pick the hittable button.
        let submitCandidates = app.buttons.matching(identifier: "Add Playlist").allElementsBoundByIndex
        guard let addPlaylist = submitCandidates.last(where: { $0.isHittable && $0.isEnabled }) ?? submitCandidates.last else {
            return XCTFail("No Add Playlist button found")
        }
        if !addPlaylist.isHittable { app.swipeUp() }
        addPlaylist.tap()

        // Validation streams the playlist head before accepting it.
        XCTAssertTrue(urlField.waitForNonExistence(timeout: 120), "Playlist was not accepted")
    }

    /// Dismisses the Settings sheet and waits for the tab bar.
    private func dismissSettingsToTabBar(_ app: XCUIApplication) {
        // iOS Settings is a sheet with no Done button (Done is macOS-only), so
        // dismiss it by dragging its navigation bar down to the bottom edge.
        let settingsNav = app.navigationBars["Settings"]
        if settingsNav.waitForExistence(timeout: 10) {
            let from = settingsNav.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
            from.press(forDuration: 0.1, thenDragTo: target)
            XCTAssertTrue(settingsNav.waitForNonExistence(timeout: 10), "Settings sheet did not dismiss")
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Tab bar not visible")
    }

    /// Switches the active playlist to the one just added.
    private func activateM3UPlaylist(_ app: XCUIApplication) {
        // Under `-ui-testing` the app also seeds an empty "Test Playlist" that
        // stays active, so switch via the library toolbar's playlist switcher.
        app.tabBars.buttons["Live TV"].tap()
        let switcher = app.playlistSwitcher(named: "Test Playlist")
        XCTAssertTrue(switcher.waitForExistence(timeout: 20), "Playlist switcher not found")
        switcher.tap()
        let item = app.buttons[playlistName].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Playlist switcher didn't list the playlist")
        item.tap()
        // Wait out the blocking switch overlay ("Switching to …").
        let switchOverlay = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Switching to")
        ).firstMatch
        if switchOverlay.waitForExistence(timeout: 5) {
            _ = switchOverlay.waitForNonExistence(timeout: 60)
        }
    }

    /// Triggers a manual sync and waits for it to finish.
    private func runManualSync(_ app: XCUIApplication) {
        let syncButton = app.syncToolbarButton
        XCTAssertTrue(syncButton.waitForExistence(timeout: 10), "Sync button not found")
        syncButton.tap()
        let startSync = app.buttons["Start Sync"]
        XCTAssertTrue(startSync.waitForExistence(timeout: 10), "Sync sheet didn't open")
        startSync.tap()
        // Generous: this downloads and imports roughly ten thousand channels
        // from a third-party host.
        let doneSync = app.buttons["Done"]
        XCTAssertTrue(doneSync.waitForExistence(timeout: 420), "m3u sync did not complete")
        doneSync.tap()
    }

    /// Verifies Live TV lists synced content and attaches a screenshot.
    private func assertLiveTVShowsContent(_ app: XCUIApplication) {
        // The invariant is "the import produced browsable channels" — not that
        // any particular category is on screen. This once looked for a "News"
        // group, which is third-party data that iptv-org reorders freely, and
        // only the first category's channels are rendered anyway.
        let channelList = app.scrollViews.firstMatch
        XCTAssertTrue(channelList.waitForExistence(timeout: 120), "Live TV never listed anything after the m3u sync")
        XCTAssertFalse(
            app.staticTexts["No Channels"].exists,
            "Live TV still shows its empty state after the m3u sync"
        )
        XCTAssertGreaterThan(channelList.buttons.count, 0, "No channels listed after the m3u sync")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LiveTV-after-m3u-sync"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
