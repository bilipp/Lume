//
//  SettingsView+Playlists.swift
//  Lume
//
//  The tvOS Playlists settings pane — the management surface: add, edit, delete,
//  and switch the active playlist. A switch made here presents the blocking sync
//  cover; the fast path that skips it is the Play/Pause quick-switch overlay
//  (TVQuickSwitchOverlay), which switches only. tvOS has no toolbar to host a
//  PlaylistSwitcher (the immersive home has none); iOS/macOS use that switcher in
//  the library toolbar instead.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        var tvPlaylistsDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                tvPlaylistsList
                tvAutoSyncSection
                TVCloudSyncSection()
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
