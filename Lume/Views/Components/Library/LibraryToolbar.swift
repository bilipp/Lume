import SwiftUI

struct LibraryToolbarModifier: ViewModifier {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    @Binding var categorySortRaw: String
    @Binding var contentSortRaw: String
    @Binding var showingSync: Bool
    @Binding var showingSettings: Bool
    let activePlaylist: Playlist?

    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if playlists.count > 1 {
                    ToolbarItem(placement: .automatic) {
                        PlaylistSwitcher(playlists: playlists, selectedPlaylistID: $selectedPlaylistID)
                    }
                }

                ToolbarItem(placement: .automatic) {
                    SortMenu(categorySortRaw: $categorySortRaw, contentSortRaw: $contentSortRaw)
                }

                // One ToolbarItem each, deliberately not an HStack in a single
                // item: when the bar runs out of room it moves surplus items
                // into a "..." overflow menu, and an item whose content is a
                // stack of buttons has no menu representation — it was dropped
                // outright, leaving no way to reach Settings at all. Separate
                // items degrade into menu rows instead. The titles also give the
                // menu rows (and VoiceOver) real names rather than the symbols'
                // defaults.
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSync = true
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .sheet(
                isPresented: $showingSettings,
                // Settings is a sheet on this toolbar, invisible to the browse
                // root that raises the rating prompt and the root notices — so
                // it reports itself, the way the paywall and the players do.
                onDismiss: { ScreenOccupancy.shared.noteBlockingSheetDismissed() },
                content: {
                    SettingsView()
                        .onAppear { ScreenOccupancy.shared.noteBlockingSheetAppeared() }
                }
            )
            .sheet(isPresented: $showingSync) {
                if let playlist = activePlaylist {
                    SyncProgressView(playlist: playlist)
                }
            }
            // A pairing link's add-device sheet is presented from the browse
            // root, which can't present over these.
            .onChange(of: router?.cloudPairingRequest?.id) { _, request in
                guard request != nil else { return }
                showingSettings = false
                showingSync = false
            }
    }
}

struct LibraryToolbarConfiguration {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    @Binding var categorySortRaw: String
    @Binding var contentSortRaw: String
    @Binding var showingSync: Bool
    @Binding var showingSettings: Bool
    let activePlaylist: Playlist?
}

extension View {
    func libraryToolbar(config: LibraryToolbarConfiguration) -> some View {
        #if os(tvOS)
            // tvOS surfaces sync/settings/sorting through the tab bar instead.
            return self
        #else
            return modifier(LibraryToolbarModifier(
                playlists: config.playlists,
                selectedPlaylistID: config.$selectedPlaylistID,
                categorySortRaw: config.$categorySortRaw,
                contentSortRaw: config.$contentSortRaw,
                showingSync: config.$showingSync,
                showingSettings: config.$showingSettings,
                activePlaylist: config.activePlaylist
            ))
        #endif
    }
}
