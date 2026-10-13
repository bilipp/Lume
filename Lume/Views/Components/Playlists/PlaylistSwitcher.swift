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
    /// The `key` value selecting the Combined view rather than one playlist.
    /// Device-local like every other selection.
    static let combined = "combined"

    /// What every switch surface calls the Combined selection — never the raw
    /// `combined` token.
    static var combinedTitle: String {
        String(
            localized: "Combined",
            comment: "Name of the Combined selection, which merges content from several playlists"
        )
    }
}

extension [Playlist] {
    /// What a switch surface calls the selection in effect: Combined, or the
    /// one playlist shown — never the raw stored token.
    func selectionTitle(for scope: CatalogScope) -> String {
        guard !scope.isCombined else { return PlaylistSelectionStore.combinedTitle }
        return primaryMember(of: scope)?.name ?? ""
    }
}

extension CatalogScope {
    /// The selection in effect, accounting for the empty-default /
    /// deleted-playlist fallback and Combined falling back to its priority-1
    /// member: `PlaylistSelectionStore.combined` for Combined itself, so no
    /// playlist row reads as active then, otherwise the playlist's
    /// `id.uuidString`, or an empty string with no playlist at all.
    var selectionID: String {
        isCombined ? PlaylistSelectionStore.combined : primaryID?.uuidString ?? ""
    }
}

// MARK: - Switcher

/// Toolbar menu that switches the global active playlist. Drop one into any
/// view's toolbar and bind it to the shared `@AppStorage` selection.
///
/// The paywall and Settings are presented by the host rather than from here:
/// a sheet attached inside a toolbar item is not reliably presented.
struct PlaylistSwitcher: View {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    let presentPaywall: (PremiumFeature) -> Void
    /// Opens Settings › Combined View, for a Pro user picking Combined before
    /// two playlists are in it.
    let openCombinedSettings: () -> Void
    /// Optional so previews (and any host that doesn't inject it) still switch
    /// instantly; when present, the switch routes through the blocking overlay.
    @Environment(PlaylistSwitchModel.self) private var switchModel: PlaylistSwitchModel?
    @Environment(\.catalogScope) private var scope
    @State private var premium = PremiumManager.shared

    var body: some View {
        let scope = scope
        let selectionID = scope.selectionID
        let selectionTitle = playlists.selectionTitle(for: scope)
        if !playlists.isEmpty {
            Menu {
                Button {
                    selectCombined()
                } label: {
                    Label(PlaylistSelectionStore.combinedTitle, systemImage: combinedSymbol(for: scope))
                }
                Divider()
                ForEach(playlists) { playlist in
                    Button {
                        select(id: playlist.id.uuidString, name: playlist.name)
                    } label: {
                        Label(
                            playlist.name,
                            systemImage: playlist.id.uuidString == selectionID ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectionTitle)
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
            .accessibilityLabel("Playlist: \(selectionTitle)")
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

    /// Switches the global selection to `id`, surfacing the re-render as a
    /// blocking overlay when a switch model is available.
    private func select(id: String, name: String) {
        guard id != scope.selectionID else { return }
        switchModel.select(id, name: name, into: $selectedPlaylistID)
    }

    private func selectCombined() {
        switch QuickSwitchResolver.combinedAction(playlists, scope: scope, isPremium: premium.isPremium) {
        case .paywall:
            presentPaywall(.multiplePlaylists)
        case .configure:
            openCombinedSettings()
        case .alreadyCurrent:
            break
        case .switchToCombined:
            switchModel.selectCombined(into: $selectedPlaylistID)
        }
    }

    /// The plain crown marks a locked action (never a "PRO" capsule).
    private func combinedSymbol(for scope: CatalogScope) -> String {
        if !premium.isPremium { return "crown" }
        return scope.isCombined ? "checkmark" : ""
    }
}

#Preview("Multiple Playlists") {
    let playlist1 = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
    let playlist2 = Playlist(name: "Backup", serverURL: "http://backup.com:8080", username: "user2", password: "pass2")
    PlaylistSwitcher(
        playlists: [playlist1, playlist2],
        selectedPlaylistID: .constant(playlist1.id.uuidString),
        presentPaywall: { _ in },
        openCombinedSettings: {}
    )
    .environment(\.catalogScope, .isolated(playlist1.id))
}

#Preview("Single Playlist") {
    let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
    PlaylistSwitcher(
        playlists: [playlist],
        selectedPlaylistID: .constant(playlist.id.uuidString),
        presentPaywall: { _ in },
        openCombinedSettings: {}
    )
    .environment(\.catalogScope, .isolated(playlist.id))
}

#Preview("Empty") {
    PlaylistSwitcher(playlists: [], selectedPlaylistID: .constant(""), presentPaywall: { _ in }, openCombinedSettings: {})
}
