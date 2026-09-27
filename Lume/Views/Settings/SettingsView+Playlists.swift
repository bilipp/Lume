//
//  SettingsView+Playlists.swift
//  Lume
//
//  The Playlists settings page: the playlist list with its sync state, Add
//  Playlist, and the shared Automatic Sync interval.
//
//  iOS / macOS: `PlaylistsSettingsView`, pushed from the root row.
//
//  tvOS: the Playlists pane — the management surface: add, edit, delete, and
//  switch the active playlist. A switch made here presents the blocking sync
//  cover; the fast path that skips it is the Play/Pause quick-switch overlay
//  (TVQuickSwitchOverlay), which switches only. tvOS has no toolbar to host a
//  PlaylistSwitcher (the immersive home has none); iOS/macOS use that switcher in
//  the library toolbar instead.
//

import SwiftData
import SwiftUI

#if !os(tvOS)

    struct PlaylistsSettingsView: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @Query private var playlists: [Playlist]
        @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
        @AppStorage(SyncFrequency.storageKey) private var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
        @State private var premium = PremiumManager.shared
        @State private var showingAddPlaylist = false
        @State private var showPaywall = false

        /// Whether a new playlist can be added for free (first playlist always free).
        private var canAddPlaylist: Bool {
            premium.isPremium || playlists.isEmpty
        }

        private var syncFrequency: Binding<SyncFrequency> {
            Binding(
                get: { SyncFrequency.resolve(syncFrequencyRaw) },
                set: { syncFrequencyRaw = $0.rawValue }
            )
        }

        var body: some View {
            List {
                playlistsSection
                autoSyncSection
            }
            .platformNavigationTitle("Playlists")
            .paywall(isPresented: $showPaywall, highlight: .multiplePlaylists)
            .sheet(isPresented: $showingAddPlaylist) {
                LoginView(isModal: true)
            }
        }

        private var playlistsSection: some View {
            Section {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name)
                                Text(playlist.displayURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 0)
                            PlaylistSyncAccessory(state: playlist.syncState(
                                isActive: playlist.id.uuidString == playlists.activeID(for: selectedPlaylistID)
                            ))
                        }
                        .padding(.vertical, 1)
                    }
                }
                .onDelete(perform: deletePlaylists)

                Button {
                    if canAddPlaylist {
                        showingAddPlaylist = true
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Label("Add Playlist", systemImage: canAddPlaylist ? "plus" : "crown")
                }
            } footer: {
                if playlists.isEmpty {
                    EmptyView()
                } else if premium.isPremium {
                    Text("\(playlists.count) playlist\(playlists.count == 1 ? "" : "s")")
                } else {
                    Text("Free includes one playlist. Upgrade to Lume Pro to add more.")
                }
            }
        }

        private var autoSyncSection: some View {
            Section {
                Picker("Refresh", selection: syncFrequency) {
                    ForEach(SyncFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)
                .disabled(playlists.isEmpty)
            } header: {
                Text("Automatic Sync")
            } footer: {
                Text("Playlists refresh automatically in the background at this interval. Disable a specific playlist's sync in its details. The TV guide refreshes on its own schedule.")
            }
        }

        private func deletePlaylists(offsets: IndexSet) {
            // Route through the sync engine so the deletion also clears the
            // CloudKit mirror and shadow baseline — deleting on the view
            // context alone leaves a surviving mirror that resurrects the last
            // playlist (#136). Previews have no coordinator; local-only
            // deletion is fine there.
            if let cloudSync {
                let ids = offsets.map { playlists[$0].id }
                Task {
                    for id in ids {
                        await cloudSync.deletePlaylist(id: id)
                    }
                }
            } else {
                withAnimation {
                    for index in offsets {
                        PlaylistDeletion.delete(playlists[index], in: modelContext)
                    }
                }
            }
        }
    }

#endif

#if os(tvOS)

    extension SettingsView {
        var tvPlaylistsDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                tvPlaylistsList
                tvAutoSyncSection
            }
        }

        private var tvPlaylistsList: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Playlists")

                if playlists.isEmpty {
                    Text("No playlists yet. Add your IPTV provider to start streaming.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(playlists) { playlist in
                        tvPlaylistRow(playlist)
                    }
                }

                Button {
                    if canAddPlaylist {
                        showingAddPlaylist = true
                    } else {
                        presentPaywall(.multiplePlaylists)
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: canAddPlaylist ? "plus" : "crown")
                            .font(.system(size: 22, weight: .medium))
                        Text("Add Playlist")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())

                if !premium.isPremium {
                    Text("Free includes one playlist. Upgrade to Lume Pro to add more.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                } else if playlists.count > 1 {
                    Text("Switching playlist changes the content shown across Home, Movies, Series and Live TV.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
            }
        }

        /// A playlist row mirroring the Profiles pane: tapping the row makes the
        /// playlist active (checkmark marks the current one); the pencil drills
        /// into its settings. The active id resolves through the same empty /
        /// deleted fallback the content tabs use, so the first playlist reads as
        /// active by default.
        private func tvPlaylistRow(_ playlist: Playlist) -> some View {
            HStack(spacing: 16) {
                TVPlaylistSwitchRow(
                    playlist: playlist,
                    isActive: playlist.id.uuidString == effectivePlaylistID
                ) {
                    switchPlaylist(to: playlist)
                }

                Button {
                    selectedPlaylist = playlist
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel("Edit \(playlist.name)")
            }
        }

        /// The active playlist's id, accounting for the empty-default / deleted
        /// fallback to the first playlist.
        private var effectivePlaylistID: String {
            playlists.activeID(for: selectedPlaylistID)
        }

        /// Switches the global selection, routing through the blocking overlay when
        /// the switch model is available (same path as the iOS toolbar switcher).
        private func switchPlaylist(to playlist: Playlist) {
            let id = playlist.id.uuidString
            guard id != effectivePlaylistID else { return }
            if let playlistSwitch {
                playlistSwitch.switchTo(name: playlist.name) { selectedPlaylistID = id }
            } else {
                selectedPlaylistID = id
            }
        }
    }

#endif
