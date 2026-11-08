//
//  DeepLinkRouter.swift
//  Lume
//

import SwiftUI

/// Shared navigation state a deep link drives: the selected tab and the Movies/
/// Series navigation stacks. `MainTabView` owns it and injects it into the
/// environment; `MoviesView` and `SeriesView` bind their `NavigationStack` to the
/// matching path so an `onOpenURL` push lands in the right tab.
///
/// It also holds the tab state that has to outlive the tab's view: tabs are
/// unmounted when not shown (tvOS) or after sitting unshown for a while
/// (`IdleUnmountingTab`, iOS/macOS), and what the viewer navigated to should
/// still be there when they come back.
@MainActor
@Observable
final class DeepLinkRouter {
    var selectedTab: AppTab = .home
    var moviesPath = NavigationPath()
    var seriesPath = NavigationPath()
    var sportsPath = NavigationPath()
    var homePath = NavigationPath()
    /// Live TV's selected rail section, and the `CatalogScope.token` it was
    /// seeded for.
    var liveTVSection: LiveTVSection?
    var liveTVSeededScopeToken: String?
    /// A `lume://cloud/pair` link asked to add a device to Lume Cloud, and the
    /// add-device sheet hasn't come up for it yet. It waits here while
    /// something the sheet can't be presented over is on screen.
    private(set) var cloudPairingRequest: LumeCloudPairingRequest?
    /// The request the add-device sheet is showing.
    var presentedCloudPairing: LumeCloudPairingRequest?
    /// Whether the sheet for `presentedCloudPairing` actually came up. SwiftUI
    /// drops a sheet without a word when its host is already presenting one it
    /// can't see — a detail screen's own sheet, say — so an attempt that never
    /// appears goes back to waiting instead of being lost.
    private(set) var cloudPairingSheetAppeared = false
    /// How many attempts in a row SwiftUI dropped; each one doubles the wait
    /// before the next, so a sheet that can't come up doesn't retry every second.
    private(set) var cloudPairingMissedAttempts = 0

    /// Whether a pairing link is waiting for, or showing, the add-device sheet.
    var hasCloudPairing: Bool {
        cloudPairingRequest != nil || presentedCloudPairing != nil
    }

    /// Queues the add-device flow for a pairing link. A newer link replaces
    /// one still waiting; one already on screen finishes first.
    func requestCloudPairing(code: String) {
        cloudPairingRequest = LumeCloudPairingRequest(code: code)
        cloudPairingMissedAttempts = 0
    }

    /// Moves the waiting request onto the sheet once `screenIsClear`.
    /// - Returns: whether the sheet was asked to come up.
    @discardableResult
    func presentPendingCloudPairing(screenIsClear: Bool) -> Bool {
        guard screenIsClear, presentedCloudPairing == nil, let request = cloudPairingRequest else { return false }
        cloudPairingRequest = nil
        cloudPairingSheetAppeared = false
        presentedCloudPairing = request
        return true
    }

    func noteCloudPairingSheetAppeared() {
        cloudPairingSheetAppeared = true
        cloudPairingMissedAttempts = 0
    }

    /// Puts a presentation that never appeared back in the queue, unless a
    /// newer link already took its place.
    func requeueCloudPairingIfNotShown() {
        guard let request = presentedCloudPairing, !cloudPairingSheetAppeared else { return }
        presentedCloudPairing = nil
        cloudPairingMissedAttempts += 1
        if cloudPairingRequest == nil {
            cloudPairingRequest = request
        }
    }

    #if os(tvOS)
        /// Whether Multi-View is covering the app. It is presented from
        /// `MainTabView` — above the tab bar — as a plain overlay rather than a
        /// `fullScreenCover`, because a tvOS cover always dismisses itself on
        /// Menu. That would make it impossible for Menu to dismiss only
        /// Multi-View's own controls overlay, which is what a viewer expects
        /// while the controls are up.
        /// Non-nil while Multi-View is up; carries the channels it opened with,
        /// when it was started from a channel's long-press menu rather than the
        /// rail button.
        var multiViewLaunch: MultiViewLaunch?

        var isMultiViewPresented: Bool {
            multiViewLaunch != nil
        }

        /// Whether the playlist/profile quick-switch modal is covering the app.
        /// Like Multi-View it is presented from `MainTabView` as a plain overlay
        /// rather than a `fullScreenCover`, because a tvOS cover always dismisses
        /// itself on Menu and nothing stops it — neither `onExitCommand` nor
        /// `interactiveDismissDisabled`. The modal needs Menu for itself so a PIN
        /// pad nested over it can consume the press first.
        var isQuickSwitchPresented = false

        /// A Settings page another surface asked for, opened — and cleared — by
        /// the Settings tab once it is on screen. tvOS Settings is a tab, not a
        /// sheet a caller could seed with `SettingsView(opening:)`.
        var pendingSettingsRoute: SettingsRoute?
    #endif
}

/// Opens the Lume Cloud add-device flow with `code` filled in. Never log the code.
struct LumeCloudPairingRequest: Identifiable, Equatable {
    let id = UUID()
    let code: String
}
