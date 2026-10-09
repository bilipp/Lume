//
//  LiveTVRailSettings.swift
//  Lume
//
//  Settings › Live TV › Categories: whether the Live TV rails (the tab's rail,
//  the tvOS in-player channel browser and the Multi-View picker) offer the
//  Favorites and Recently Watched collections. Both default on. Stored in
//  UserDefaults and synced across devices by `CloudSyncEngine+Preferences`.
//

import Foundation

nonisolated enum LiveTVRailSettings {
    static let showsFavoritesKey = "lume.liveTV.showsFavorites"
    static let showsFavoritesDefault = true
    static let showsRecentlyWatchedKey = "lume.liveTV.showsRecentlyWatched"
    static let showsRecentlyWatchedDefault = true

    /// The stored choice, or nil when neither switch has ever been written on
    /// this device. Nil is what lets a fresh device adopt the cloud's value
    /// instead of reading its defaults as a local edit to push.
    static func storedValues(in defaults: UserDefaults) -> LiveTVPreferenceValues? {
        let favorites = defaults.object(forKey: showsFavoritesKey) as? Bool
        let recents = defaults.object(forKey: showsRecentlyWatchedKey) as? Bool
        guard favorites != nil || recents != nil else { return nil }
        return LiveTVPreferenceValues(
            showsFavorites: favorites ?? showsFavoritesDefault,
            showsRecentlyWatched: recents ?? showsRecentlyWatchedDefault
        )
    }

    /// Writes a merged value back. Nil returns both switches to their defaults.
    static func store(_ value: LiveTVPreferenceValues?, in defaults: UserDefaults) {
        guard let value else {
            defaults.removeObject(forKey: showsFavoritesKey)
            defaults.removeObject(forKey: showsRecentlyWatchedKey)
            return
        }
        defaults.set(value.showsFavorites, forKey: showsFavoritesKey)
        defaults.set(value.showsRecentlyWatched, forKey: showsRecentlyWatchedKey)
    }
}
