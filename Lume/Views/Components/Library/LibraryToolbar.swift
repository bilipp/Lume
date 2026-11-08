import SwiftData
import SwiftUI

struct LibraryToolbarModifier: ViewModifier {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    @Binding var categorySortRaw: String
    @Binding var contentSortRaw: String
    @Binding var showingSync: Bool
    @Binding var showingSettings: Bool
    @Environment(\.catalogScope) private var catalogScope
    /// The page Settings opens on, set by the switcher's Combined entry and
    /// cleared when Settings closes so the toolbar's own gear opens the root.
    @State private var settingsRoute: SettingsRoute?
    @State private var showPaywall = false
    @State private var paywallHighlight: PremiumFeature?

    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if playlists.count > 1 {
                    ToolbarItem(placement: .automatic) { playlistSwitcher }
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
                    LibrarySyncButton(playlists: playlists, scope: catalogScope, showingSync: $showingSync)
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
                onDismiss: {
                    settingsRoute = nil
                    ScreenOccupancy.shared.noteBlockingSheetDismissed()
                },
                content: {
                    SettingsView(opening: settingsRoute)
                        .onAppear { ScreenOccupancy.shared.noteBlockingSheetAppeared() }
                }
            )
            .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
            // The Sync sheet syncs one playlist; Combined queues every member
            // through `AutoSyncQueue` instead.
            .sheet(isPresented: $showingSync) {
                if let playlist = playlists.primaryMember(of: catalogScope) {
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

    private var playlistSwitcher: some View {
        PlaylistSwitcher(
            playlists: playlists,
            selectedPlaylistID: $selectedPlaylistID,
            presentPaywall: { feature in
                paywallHighlight = feature
                showPaywall = true
            },
            openCombinedSettings: {
                settingsRoute = .combinedView
                showingSettings = true
            }
        )
    }
}

/// Sync for the playlist on screen, or — while Combined is on screen — every
/// due member, queued one after another by `AutoSyncQueue` rather than in a
/// sheet here. Its own view so the queue's busy flag re-renders this button only.
private struct LibrarySyncButton: View {
    let playlists: [Playlist]
    let scope: CatalogScope
    @Binding var showingSync: Bool
    @Environment(AutoSyncQueue.self) private var autoSyncQueue: AutoSyncQueue?
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SyncFrequency.storageKey) private var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue

    private var syncsMembers: Bool {
        autoSyncQueue != nil && scope.isCombined
    }

    var body: some View {
        Button {
            if syncsMembers, let autoSyncQueue {
                autoSyncQueue.enqueueManualMembers(
                    scope: scope,
                    playlists: playlists,
                    frequency: SyncFrequency.resolve(syncFrequencyRaw),
                    context: modelContext
                )
            } else {
                showingSync = true
            }
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(syncsMembers && autoSyncQueue?.isBusy == true)
    }
}

struct LibraryToolbarConfiguration {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    @Binding var categorySortRaw: String
    @Binding var contentSortRaw: String
    @Binding var showingSync: Bool
    @Binding var showingSettings: Bool
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
                showingSettings: config.$showingSettings
            ))
        #endif
    }
}
