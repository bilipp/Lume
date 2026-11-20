//
//  LibrarySettings.swift
//  Lume
//
//  Device-local browse preferences. Never synced.
//

import Foundation

nonisolated enum LibrarySettings {
    /// Whether the copies of one title (qualities, languages, playlists) show
    /// as a single card. Off (the default while it is in beta) lists every
    /// catalog row as the provider sent it.
    static let groupDuplicateTitlesKey = "library.groupDuplicateTitles"
    static let groupDuplicateTitlesDefault = false

    static func groupDuplicateTitles(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(groupDuplicateTitlesKey, default: groupDuplicateTitlesDefault)
    }
}
