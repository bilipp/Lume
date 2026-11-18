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

    /// Whether a title's source picker also lists its copies on playlists
    /// outside the current scope (the active playlist, or the Combined View
    /// members). On by default: before titles were grouped, every installed
    /// playlist's copy was offered.
    static let sourcesFromAllPlaylistsKey = "library.sourcesFromAllPlaylists"
    static let sourcesFromAllPlaylistsDefault = true

    static func sourcesFromAllPlaylists(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(sourcesFromAllPlaylistsKey, default: sourcesFromAllPlaylistsDefault)
    }
}
