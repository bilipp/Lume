//
//  UITestLaunchReset.swift
//  Lume
//

import Foundation

/// Every tab setting a UI test can change, reset at each UI-test launch so
/// one test's layout doesn't leak into the tests launched after it.
enum UITestLaunchReset {
    /// The device-wide tab layout. Run before any view exists: `MainTabView`
    /// and `DeepLinkRouter` pick the landing tab from these keys when they
    /// are created.
    static func resetDeviceTabLayout(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: TabLayoutSettings.orderKey)
        defaults.removeObject(forKey: TabLayoutSettings.homeEnabledKey)
    }

    /// The tabs hidden in Settings › Library, which persist on the playlist.
    /// Run once the catalog is ready.
    static func resetPlaylistTabs(_ playlists: [Playlist]) {
        for playlist in playlists where !playlist.hiddenTabsRaw.isEmpty {
            playlist.hiddenTabsRaw = ""
        }
    }
}
