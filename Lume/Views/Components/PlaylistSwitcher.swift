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
                HStack(spacing: 4) {
                    Text(effectiveName)
                        .font(.headline)
                        // A long playlist name must never grow this label
                        // unbounded: the navigation bar answers an over-wide
                        // trailing item by collapsing *every* trailing item into
                        // a "..." overflow menu, which used to take the sync and
                        // settings buttons off screen with it (issue: settings
                        // unreachable with a long playlist name). Cap the width
                        // and truncate — the full name is still spelled out in
                        // the menu below and read out by VoiceOver.
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .frame(maxWidth: Self.maxLabelWidth, alignment: .leading)
            }
            .accessibilityLabel("Playlist: \(effectiveName)")
        }
    }

    // Width ceiling for the label in the toolbar. Deliberately a fixed value
    // rather than a `@ScaledMetric` one: growing it with Dynamic Type would
    // re-create the overflow this cap exists to prevent.
    #if os(macOS)
        private static let maxLabelWidth: CGFloat = 260
    #else
        private static let maxLabelWidth: CGFloat = 150
    #endif

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
        playlists.activeID(for: selectedPlaylistID)
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
