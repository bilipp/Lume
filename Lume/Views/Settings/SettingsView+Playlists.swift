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
        @Environment(\.catalogScope) private var catalogScope
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
                if !playlists.isEmpty {
                    combinedSection
                }
                autoSyncSection
            }
            .platformNavigationTitle("Playlists")
            .paywall(isPresented: $showPaywall, highlight: .multiplePlaylists)
            .sheet(isPresented: $showingAddPlaylist) {
                LoginView(isModal: true)
            }
        }

        private var playlistsSection: some View {
            let scope = catalogScope
            return Section {
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
                                isActive: scope.playlistIDs.contains(playlist.id)
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

        /// The row opens the paywall or the Combined View page, per
        /// `QuickSwitchResolver.combinedSettingsAction`.
        private var combinedSection: some View {
            Section {
                if QuickSwitchResolver.combinedSettingsAction(playlists, isPremium: premium.isPremium) == .paywall {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack(spacing: 8) {
                            combinedLabel
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        CombinedPlaylistsSettingsView()
                    } label: {
                        combinedLabel
                    }
                }
            } footer: {
                Text("Browse Live TV, Movies and Series from several playlists together.")
            }
        }

        private var combinedLabel: some View {
            HStack(spacing: 6) {
                Text("Combined View")
                if !premium.isPremium {
                    PremiumBadge()
                }
                Spacer(minLength: 0)
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
                if !playlists.isEmpty {
                    tvCombinedSection
                }
                tvAutoSyncSection
            }
        }

        /// The row opens the paywall or the Combined View page, per
        /// `QuickSwitchResolver.combinedSettingsAction`.
        private var tvCombinedSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if QuickSwitchResolver.combinedSettingsAction(playlists, isPremium: premium.isPremium) == .paywall {
                        presentPaywall(.multiplePlaylists)
                    } else {
                        beginContentManagementHandoff()
                        showingCombinedView = true
                    }
                } label: {
                    HStack(spacing: 16) {
                        Text("Combined View")
                        if !premium.isPremium {
                            PremiumBadge()
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                Text("Browse Live TV, Movies and Series from several playlists together.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
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
                    let scope = catalogScope
                    let column = QuickSwitchResolver.playlistColumn(playlists, scope: scope, isPremium: premium.isPremium)
                    TVCombinedSwitchRow(
                        memberNames: column.combinedMemberNames,
                        isActive: column.isCombinedCurrent,
                        isLocked: column.combinedAction == .paywall
                    ) {
                        selectCombined(column.combinedAction)
                    }
                    ForEach(playlists) { playlist in
                        tvPlaylistRow(playlist, scope: scope)
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
        private func tvPlaylistRow(_ playlist: Playlist, scope: CatalogScope) -> some View {
            HStack(spacing: 16) {
                TVPlaylistSwitchRow(
                    playlist: playlist,
                    isActive: playlist.id.uuidString == scope.selectionID,
                    isInScope: scope.playlistIDs.contains(playlist.id)
                ) {
                    switchPlaylist(to: playlist, from: scope)
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

        /// Switches the global selection, routing through the blocking overlay when
        /// the switch model is available (same path as the iOS toolbar switcher).
        private func switchPlaylist(to playlist: Playlist, from scope: CatalogScope) {
            let id = playlist.id.uuidString
            guard id != scope.selectionID else { return }
            playlistSwitch.select(id, name: playlist.name, into: $selectedPlaylistID)
        }

        private func selectCombined(_ action: CombinedSwitchAction) {
            switch action {
            case .paywall:
                presentPaywall(.multiplePlaylists)
            case .configure:
                beginContentManagementHandoff()
                showingCombinedView = true
            case .alreadyCurrent:
                break
            case .switchToCombined:
                playlistSwitch.selectCombined(into: $selectedPlaylistID)
            }
        }
    }

#endif
