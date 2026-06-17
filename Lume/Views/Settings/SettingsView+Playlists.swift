//
//  SettingsView+Playlists.swift
//  Lume
//
//  The tvOS Playlists settings pane. tvOS has no toolbar playlist switcher (the
//  immersive home has no toolbar), so Settings is the entry point for switching
//  the active playlist, adding new ones and editing them — mirroring the Profiles
//  pane. iOS/macOS use the PlaylistSwitcher in the library toolbar instead.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        var tvPlaylistsDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                tvPlaylistsList
                tvAutoSyncSection
                tvIndexingSection
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
            let isActive = playlist.id.uuidString == effectivePlaylistID
            return HStack(spacing: 16) {
                Button {
                    switchPlaylist(to: playlist)
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                            Text(playlist.serverURL)
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())

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
        /// fallback to the first playlist (matches `[Playlist].active(for:)`).
        private var effectivePlaylistID: String {
            playlists.active(for: selectedPlaylistID)?.id.uuidString ?? ""
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
