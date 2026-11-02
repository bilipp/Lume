import XCTest

final class NavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    func testTabBarExists() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testNavigationToMovies() {
        let moviesTab = app.tabBars.buttons["Movies"]
        XCTAssertTrue(moviesTab.waitForExistence(timeout: 5))
        moviesTab.tap()
        XCTAssertTrue(app.navigationBars["Movies"].waitForExistence(timeout: 3))
    }

    func testNavigationToSeries() {
        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(seriesTab.waitForExistence(timeout: 5))
        seriesTab.tap()
        XCTAssertTrue(app.navigationBars["Series"].waitForExistence(timeout: 3))
    }

    func testNavigationToLiveTV() {
        let liveTab = app.tabBars.buttons["Live TV"]
        XCTAssertTrue(liveTab.waitForExistence(timeout: 5))
        liveTab.tap()
        // Live TV carries no navigation title, so check the tab selection instead.
        XCTAssertTrue(app.waitForSelection(of: liveTab))
    }

    func testNavigationToHome() {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        // Home is selected at launch; leave it first so the tap proves something.
        let moviesTab = app.tabBars.buttons["Movies"]
        moviesTab.tap()
        XCTAssertTrue(app.waitForSelection(of: moviesTab))
        homeTab.tap()
        // Home carries no navigation title, so check the tab selection instead.
        XCTAssertTrue(app.waitForSelection(of: homeTab))
    }

    func testAllTabsAreAccessible() {
        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs["Home"].exists)
        XCTAssertTrue(tabs["Movies"].exists)
        XCTAssertTrue(tabs["Series"].exists)
        XCTAssertTrue(tabs["Live TV"].exists)
    }
}

private extension XCUIApplication {
    /// Waits for a tab-bar button to report itself selected.
    func waitForSelection(of tab: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab)
        return XCTWaiter.wait(for: [selected], timeout: timeout) == .completed
    }
}
