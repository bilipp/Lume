import XCTest

/// Shared element queries for the UI tests, each pinned to what the app
/// actually publishes rather than to what the SwiftUI source reads like.
extension XCUIApplication {
    /// The library toolbar's Settings and Sync buttons.
    ///
    /// These were once matched by their SF Symbol names ("gear", "Syncing"),
    /// which is what XCUITest falls back to when a `Label` carries no title.
    /// The toolbar since gives every button a real title so it keeps a name
    /// when the bar collapses into the "•••" overflow menu — at which point
    /// the symbol-name queries matched nothing and every flow test failed on
    /// its first tap. Both spellings are accepted so the query does not depend
    /// on which the running OS decides to publish.
    var settingsToolbarButton: XCUIElement {
        toolbarButton(title: "Settings", symbol: "gear")
    }

    var syncToolbarButton: XCUIElement {
        toolbarButton(title: "Sync", symbol: "Syncing")
    }

    /// Opens the Settings sheet from the library toolbar.
    ///
    /// Waits for the main UI before tapping: every test here launches a cold
    /// app, which spends its first seconds on the launch screen and the store
    /// load. A tap issued before the toolbar exists resolves against nothing,
    /// and the failure then surfaces as "Settings never appeared" several
    /// seconds later rather than as the missed tap it was.
    func openSettingsSheet(timeout: TimeInterval = 60) -> Bool {
        guard tabBars.firstMatch.waitForExistence(timeout: timeout) else { return false }
        settingsToolbarButton.tap()
        return navigationBars["Settings"].waitForExistence(timeout: timeout)
    }

    /// The toolbar's playlist switcher for the playlist named `name`.
    ///
    /// The switcher carries an explicit `accessibilityLabel` of
    /// "Playlist: <name>", so it is not reachable as `buttons[name]` — that
    /// only matches the `Text` nested inside it, which is not the tappable
    /// element. Both spellings are accepted so the query survives either.
    func playlistSwitcher(named name: String) -> XCUIElement {
        buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playlist: \(name)", name)
        ).firstMatch
    }

    /// Scrolls the screen up until `element` exists, and reports whether it
    /// ever did.
    ///
    /// Settings is a lazy SwiftUI `List` of about twenty sections: a row below
    /// the fold is not merely off screen, it is absent from the accessibility
    /// tree entirely, so `waitForExistence` alone can never find one however
    /// long it waits.
    func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 15) -> Bool {
        for _ in 0 ..< maxSwipes {
            if element.exists { return true }
            swipeUp()
        }
        return element.exists
    }

    private func toolbarButton(title: String, symbol: String) -> XCUIElement {
        buttons.matching(
            NSPredicate(
                format: "label == %@ OR identifier == %@ OR label == %@ OR identifier == %@",
                title, title, symbol, symbol
            )
        ).firstMatch
    }
}
