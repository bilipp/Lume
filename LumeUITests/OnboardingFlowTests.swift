import XCTest

/// End-to-end cover of the first-launch "How Lume Works" guide: page through it
/// to the add-playlist hand-off, then relaunch and confirm the stored version
/// keeps it down.
///
/// The guide launch runs *without* `-ui-testing`, unlike the suites that assert
/// on the tab bar: that argument is exactly what suppresses the guide, and it
/// also seeds a placeholder playlist, which sends the launch chain to the tab
/// bar instead.
///
/// The guide's own controls are matched by accessibility identifier, so the walk
/// survives localization.
final class OnboardingFlowTests: XCTestCase {
    /// Argument-domain override that puts the stored guide version back to its
    /// default for one launch. `UserDefaults` reads the argument domain ahead of
    /// the app's own, so the guide comes back without a production reset hook —
    /// and the version the guide writes on finish still lands in the persistent
    /// domain, which is what the launch after it reads.
    private let resetSeenVersion = ["-onboarding.seenVersion.v1", "0"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The launch-configuration matrix in LumeUITestsLaunchTests leaves the
        // device wherever it finished; the walk below should not inherit that.
        XCUIDevice.shared.orientation = .portrait
    }

    func testGuideRunsOnceThenStaysDownOnRelaunch() throws {
        let app = XCUIApplication()
        try emptyTheCatalog(in: app)

        app.launchArguments = resetSeenVersion
        app.launch()

        // The guide waits behind the launch-time iCloud gate, which has a 15 s
        // safety-net timeout of its own — hence the unusually long wait.
        let continueButton = app.buttons["onboarding.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 45), "A fresh launch should open on the guide")
        XCTAssertTrue(app.buttons["onboarding.skip"].exists, "The first-launch guide offers Skip")

        // Page through to the hand-off. Bounded rather than counted, so adding a
        // step to the tour doesn't turn into a failing UI test; the last press
        // leaves the guide, which is what ends the loop.
        var pagesVisited = 0
        while pagesVisited < 12, continueButton.waitForExistence(timeout: 3) {
            continueButton.tap()
            pagesVisited += 1
        }
        XCTAssertGreaterThan(pagesVisited, 1, "The guide should have more than one page")
        XCTAssertLessThan(pagesVisited, 12, "The guide never handed off — it is still on screen")

        // The last page hands off to the existing add-playlist form.
        let nameField = app.textFields["e.g. My IPTV"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "Finishing the guide should reveal the add-playlist form")

        // Relaunch without the override: the version the guide stored on finish
        // is now the one the app reads, so the guide must not come back.
        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(nameField.waitForExistence(timeout: 45), "A second launch should go straight to the add-playlist form")
        XCTAssertFalse(app.buttons["onboarding.continue"].exists, "The guide should stay down once it has been seen")
        XCTAssertFalse(app.buttons["onboarding.skip"].exists, "The guide should stay down once it has been seen")
    }

    // MARK: - Helpers

    /// Clears the catalog so the launch chain reaches the guide — a populated
    /// catalog opens straight on the tab bar and the guide's branch never runs.
    /// Ends with the app terminated.
    ///
    /// Deletes only playlists this suite recognises as UI-test fixtures. The
    /// simulator container is shared with whatever the developer running the
    /// suite has added by hand, and a test may not delete a stranger's data to
    /// make room for itself; anything unrecognised skips the test instead.
    ///
    /// This pass launches *with* `-ui-testing` on purpose — it suppresses the
    /// blocking auto-sync cover that a never-synced leftover playlist otherwise
    /// puts over the whole UI. Its own seeded playlist is one of the fixtures.
    private func emptyTheCatalog(in app: XCUIApplication) throws {
        app.launchArguments = ["-ui-testing"]
        app.launch()
        defer { app.terminate() }

        guard app.tabBars.firstMatch.waitForExistence(timeout: 20) else { return }
        // Settings is a toolbar item on the compact layout and a tab elsewhere.
        let settingsEntry = app.buttons["Settings"].firstMatch
        let gearTab = app.buttons["gear"]
        guard settingsEntry.waitForExistence(timeout: 10) || gearTab.exists else {
            XCTFail("Could not reach Settings to clear the catalog")
            return
        }
        (settingsEntry.exists ? settingsEntry : gearTab).tap()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 20))

        // Playlist rows are the only ones in Settings showing a server URL.
        let rows = app.cells.containing(NSPredicate(format: "label CONTAINS[c] 'http'"))
        while true {
            let remaining = rows.count
            guard remaining > 0 else { return }
            let row = rows.element(boundBy: 0)
            // The cell's own `label` is empty — the name and server URL are child
            // static texts — so identify the playlist by its descendants.
            let label = row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            guard Self.fixtureMarkers.contains(where: { label.localizedCaseInsensitiveContains($0) }) else {
                throw XCTSkip(
                    "Simulator holds a playlist this suite did not create (\(label)). "
                        + "Refusing to delete it — run this suite on a simulator without "
                        + "hand-added playlists, or erase the simulator first."
                )
            }
            row.swipeLeft()
            let deleteButton = app.buttons["Delete"]
            guard deleteButton.waitForExistence(timeout: 5) else {
                XCTFail("Playlist row did not offer Delete")
                return
            }
            deleteButton.tap()
            // The deletion takes the playlist's whole catalog with it, so the row
            // outlives the tap by a moment — a full import is a lot of rows.
            guard poll(timeout: 120, until: { rows.count < remaining }) else {
                XCTFail("Playlist deletion did not complete")
                return
            }
        }
    }

    /// Playlists created by this repo's own UI suites: `ContentView`'s
    /// `-ui-testing` seed, and the fixtures `M3UPlaylistFlowTests` and
    /// `StalkerPortalFlowTests` add.
    private static let fixtureMarkers = ["Test Playlist", "test.example.com", "iptv-org", "Example Portal"]

    /// Polls `condition` until it holds or the timeout expires. XCUITest can wait
    /// on one element, but not on "this query returns fewer elements", which is
    /// the shape of an asynchronous delete.
    private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.5)
        }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }
}
