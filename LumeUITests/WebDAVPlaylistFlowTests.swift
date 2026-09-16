import XCTest

/// End-to-end WebDAV add-playlist flow through the login form.
///
/// There is no WebDAV server to add against here, so this covers the form
/// itself: the segment gating the fields, and that a failed connection test
/// reports rather than silently adding the playlist. Which of the four
/// failures gets which copy is decided by `WebDAVAddCheck.message` and covered
/// in `WebDAVAddCheckTests` — pure, and so not at the mercy of what a host on
/// the build machine happens to answer.
final class WebDAVPlaylistFlowTests: XCTestCase {
    /// Port 1 (`tcpmux`) is never listening, so the connect fails immediately
    /// rather than waiting out the form's 20s deadline — and `localhost`
    /// classifies as a local address, which is what selects the
    /// local-network copy.
    private let unreachableShare = "http://localhost:1/Movies/"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tests

    func testWebDAVShareThatCannotBeReachedExplainsLocalNetworkPermission() {
        let app = XCUIApplication()
        launchAndOpenAddForm(app)
        selectWebDAVSegment(app)
        fillWebDAVForm(app, url: unreachableShare, username: "bilipp", password: "test")
        submit(app)

        // A declined local-network prompt is indistinguishable from an
        // unreachable host, and only the system Settings app can reverse it —
        // so the copy has to name Settings or the user has no way forward.
        let error = errorText(app, containing: "local network")
        XCTAssertTrue(error.waitForExistence(timeout: 30), "No local-network error surfaced.\n\(app.debugDescription)")
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("Settings"), "Error doesn't point at Settings: \(error.label)")

        // The form must still be standing: a failed connection test may never
        // insert the playlist and dismiss.
        XCTAssertTrue(shareURLField(app).exists, "Form was dismissed despite a failed connection test")
    }

    /// The WebDAV fields only exist while the WebDAV segment is selected — the
    /// form dispatches the whole field stack off `sourceType`.
    func testWebDAVFieldsAppearOnlyForTheWebDAVSegment() {
        let app = XCUIApplication()
        launchAndOpenAddForm(app)

        selectWebDAVSegment(app)
        XCTAssertTrue(shareURLField(app).waitForExistence(timeout: 5))

        // Attached so the four-segment picker can be eyeballed at the narrowest
        // supported width, where a fifth source type would start truncating.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WebDAV-add-form"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Xtream"].tap()
        XCTAssertTrue(shareURLField(app).waitForNonExistence(timeout: 5), "Share URL field outlived the WebDAV segment")
    }

    // MARK: - Steps

    /// Launches the app and opens the add-playlist form.
    private func launchAndOpenAddForm(_ app: XCUIApplication) {
        // `-ui-testing` disables CloudKit (which hard-crashes on the un-entitled
        // test binary) and seeds an empty placeholder playlist, so the app opens
        // on the tab bar — we add the share through Settings.
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // Fresh install shows the login form as root; otherwise add via Settings.
        if app.tabBars.firstMatch.waitForExistence(timeout: 5) {
            app.settingsToolbarButton.tap()
            let addButton = app.buttons["Add Playlist"]
            XCTAssertTrue(addButton.waitForExistence(timeout: 3))
            addButton.tap()
        }
    }

    private func selectWebDAVSegment(_ app: XCUIApplication) {
        let segment = app.buttons["WebDAV"]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "No WebDAV segment.\n\(app.debugDescription)")
        segment.tap()
    }

    private func shareURLField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["e.g. http://192.168.1.10:8080/Movies/"]
    }

    private func fillWebDAVForm(_ app: XCUIApplication, url: String, username: String, password: String) {
        let nameField = app.textFields["e.g. My Media Server"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "No WebDAV name field.\n\(app.debugDescription)")
        nameField.tap()
        nameField.typeText("My NAS")

        let urlField = shareURLField(app)
        urlField.tap()
        urlField.typeText(url)

        if !username.isEmpty {
            let userField = app.textFields["Username (optional)"]
            userField.tap()
            userField.typeText(username)

            let passwordField = app.secureTextFields["Password (optional)"]
            passwordField.tap()
            // Trailing newline dismisses the keyboard — it otherwise covers the
            // submit button, and XCUITest taps don't scroll covered elements in.
            passwordField.typeText(password + "\n")
        } else {
            urlField.typeText("\n")
        }
    }

    private func submit(_ app: XCUIApplication) {
        // More than one element can carry the "Add Playlist" label (navigation
        // title vs. submit button), so pick the hittable button.
        let candidates = app.buttons.matching(identifier: "Add Playlist").allElementsBoundByIndex
        guard let addPlaylist = candidates.last(where: { $0.isHittable && $0.isEnabled }) ?? candidates.last else {
            return XCTFail("No Add Playlist button found")
        }
        if !addPlaylist.isHittable { app.swipeUp() }
        addPlaylist.tap()
    }

    /// The error is rendered as a `Label`, which publishes its title as a
    /// static text — matched on a substring so the assertion survives copy
    /// edits and localization.
    private func errorText(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", fragment)
        ).firstMatch
    }
}
