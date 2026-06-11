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

    var body: some View {
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        selectedPlaylistID = playlist.id.uuidString
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

    /// The id that is actually in effect, accounting for the empty-default /
    /// deleted-playlist fallback to the first playlist.
    private var effectiveID: String {
        playlists.active(for: selectedPlaylistID)?.id.uuidString ?? ""
    }

    private var effectiveName: String {
        playlists.active(for: selectedPlaylistID)?.name ?? ""
    }
}

// MARK: - tvOS switcher

#if os(tvOS)
    /// Floating playlist switch for the tvOS library screens: a compact button
    /// pinned below the tab bar in the top-right corner. tvOS has no `Menu`,
    /// so pressing it presents the playlist list as a confirmation dialog.
    /// Hidden with a single playlist — there is nothing to switch to.
    private struct TVPlaylistSwitcherModifier: ViewModifier {
        let playlists: [Playlist]
        @Binding var selectedPlaylistID: String

        @State private var showingPicker = false

        func body(content: Content) -> some View {
            content.overlay(alignment: .topTrailing) {
                if playlists.count > 1 {
                    switchButton
                }
            }
        }

        private var switchButton: some View {
            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack")
                        .font(.caption)
                    Text(playlists.active(for: selectedPlaylistID)?.name ?? "")
                        .lineLimit(1)
                }
                .font(.callout)
            }
            // A lone narrow target at the screen edge: the section gives the
            // focus engine an explicit group so "up" from right-side content
            // can land here instead of skipping straight to the tab bar.
            .focusSection()
            .confirmationDialog("Switch Playlist", isPresented: $showingPicker, titleVisibility: .visible) {
                ForEach(playlists) { playlist in
                    Button {
                        selectedPlaylistID = playlist.id.uuidString
                    } label: {
                        if playlist.id == playlists.active(for: selectedPlaylistID)?.id {
                            Label(playlist.name, systemImage: "checkmark")
                        } else {
                            Text(playlist.name)
                        }
                    }
                }
            }
        }
    }
#endif

extension View {
    /// tvOS: pins the compact playlist switch to the view's top-right corner.
    /// No-op everywhere else — iOS/macOS get `PlaylistSwitcher` via the
    /// library toolbar instead. Attach to a tab's ROOT content (inside its
    /// `NavigationStack`) so the switch disappears on pushed detail screens.
    @ViewBuilder
    func tvPlaylistSwitcher(playlists: [Playlist], selectedPlaylistID: Binding<String>) -> some View {
        #if os(tvOS)
            modifier(TVPlaylistSwitcherModifier(playlists: playlists, selectedPlaylistID: selectedPlaylistID))
        #else
            self
        #endif
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
