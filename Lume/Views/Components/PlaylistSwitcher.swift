//
//  PlaylistSwitcher.swift
//  Lume
//
//  The playlist selection is a single global setting shared by Home, Movies,
//  Series and Live TV. It is persisted as the selected playlist's UUID string
//  in UserDefaults so the choice survives launches and stays in sync across
//  every tab.
//

import SwiftUI

// MARK: - Selection store

enum PlaylistSelectionStore {
    /// `@AppStorage` key holding the selected playlist's `id.uuidString`.
    /// An empty value means "no explicit choice yet" — callers fall back to the
    /// first playlist.
    static let key = "lume.selectedPlaylistID"
}

extension [Playlist] {
    /// Resolves the stored selection to a concrete playlist, falling back to the
    /// first available playlist when the stored id is empty or no longer exists
    /// (e.g. the selected playlist was deleted).
    func active(for storedID: String) -> Playlist? {
        first(where: { $0.id.uuidString == storedID }) ?? first
    }
}

// MARK: - Switcher

/// Toolbar menu that switches the global active playlist. Drop one into any
/// view's toolbar and bind it to the shared `@AppStorage` selection.
struct PlaylistSwitcher: View {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    /// Optional so previews (and any host that doesn't inject it) still switch
    /// instantly; when present, the switch routes through the blocking overlay.
    @Environment(PlaylistSwitchModel.self) private var switchModel: PlaylistSwitchModel?

    var body: some View {
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        select(playlist)
                    } label: {
                        Label(
                            playlist.name,
                            systemImage: playlist.id.uuidString == effectiveID ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                HStack {
                    Text(effectiveName)
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
            }
        }
    }

    /// Switches the global selection to `playlist`, surfacing the re-render as a
    /// blocking overlay when a switch model is available.
    private func select(_ playlist: Playlist) {
        let id = playlist.id.uuidString
        guard id != effectiveID else { return }
        if let switchModel {
            switchModel.switchTo(name: playlist.name) { selectedPlaylistID = id }
        } else {
            selectedPlaylistID = id
        }
    }

    /// The id that is actually in effect, accounting for the empty-default /
    /// deleted-playlist fallback to the first playlist.
    private var effectiveID: String {
        playlists.active(for: selectedPlaylistID)?.id.uuidString ?? ""
    }

    private var effectiveName: String {
        playlists.active(for: selectedPlaylistID)?.name ?? ""
    }
}

#Preview("Multiple Playlists") {
    let playlist1 = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
    let playlist2 = Playlist(name: "Backup", serverURL: "http://backup.com:8080", username: "user2", password: "pass2")
    PlaylistSwitcher(playlists: [playlist1, playlist2], selectedPlaylistID: .constant(playlist1.id.uuidString))
}

#Preview("Single Playlist") {
    let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
    PlaylistSwitcher(playlists: [playlist], selectedPlaylistID: .constant(playlist.id.uuidString))
}

#Preview("Empty") {
    PlaylistSwitcher(playlists: [], selectedPlaylistID: .constant(""))
}
