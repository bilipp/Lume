//
//  PlaylistDetailView+TV.swift
//  Lume
//
//  The tvOS layout for a playlist's detail pane: the connection fields, account
//  info, stream-format and sync sections, and the edit/delete actions. Split out
//  of PlaylistDetailView to keep that file within the project's line-count cap.
//

import SwiftUI

#if os(tvOS)

    extension PlaylistDetailView {
        /// Rendered *inline* inside the Settings detail pane (next to the sidebar),
        /// not pushed full-screen. A push hides the TabView's header tab bar and
        /// strands focus once the content scrolls — keeping it in the pane means
        /// the sidebar and tab bar stay one "Left"/"Up" away at all times. The
        /// enclosing pane supplies the ScrollView, background, and width framing.
        var tvBody: some View {
            VStack(alignment: .leading, spacing: 32) {
                Text(playlist.name)
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                tvServerSection
                tvAccountSection
                tvStreamFormatSection
                tvSyncSection
                tvActionsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alert("Delete Playlist", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deletePlaylist() }
            } message: {
                Text("All synced content for this playlist will also be removed.")
            }
            .fullScreenCover(isPresented: $showSync) {
                SyncProgressView(playlist: playlist)
            }
            .fullScreenCover(isPresented: $showFullSync) {
                SyncProgressView(playlist: playlist, full: true)
            }
        }

        var tvServerSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel(connectionSectionTitle)

                if isEditing {
                    VStack(spacing: 18) {
                        TVSettingsField(title: "Name", placeholder: "Name", text: $editName, contentType: .name)
                        TVSettingsField(title: serverURLFieldTitle, placeholder: serverURLFieldTitle, text: $editServerURL, contentType: .URL)
                        if isM3U {
                            TVSettingsField(title: "EPG URL (optional)", placeholder: "EPG URL", text: $editEPGURL, contentType: .URL)
                        } else if isStalker {
                            TVSettingsField(title: "MAC Address", placeholder: "00:1A:79:xx:xx:xx", text: $editMacAddress, contentType: nil)
                            TVSettingsField(title: "Username (optional)", placeholder: "Username", text: $editUsername, contentType: .username)
                            TVSettingsField(title: "Password (optional)", placeholder: "Password", text: $editPassword, isSecure: true, contentType: .password)
                        } else {
                            TVSettingsField(title: "Username", placeholder: "Username", text: $editUsername, contentType: .username)
                            TVSettingsField(title: "Password", placeholder: "Password", text: $editPassword, isSecure: true, contentType: .password)
                        }
                    }
                } else {
                    VStack(spacing: 2) {
                        TVSettingsValueRow("Name", value: playlist.name)
                        TVSettingsValueRow(isStalker ? "Portal URL" : "URL") {
                            Text(playlist.serverURL)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if isM3U {
                            TVSettingsValueRow("EPG URL") {
                                Text(playlist.epgURL ?? String(localized: "None"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else if isStalker {
                            TVSettingsValueRow("MAC Address", value: playlist.macAddress ?? "")
                            if !playlist.username.isEmpty {
                                TVSettingsValueRow("Username", value: playlist.username)
                            }
                        } else {
                            TVSettingsValueRow("Username", value: playlist.username)
                            TVSettingsValueRow("Password") { Text("••••••••") }
                        }
                        TVSettingsValueRow("Added") { Text(playlist.addedAt, style: .date) }
                    }
                }
            }
        }

        @ViewBuilder
        var tvAccountSection: some View {
            if let status = playlist.userStatus {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Account")

                    VStack(spacing: 2) {
                        TVSettingsValueRow("Status", value: status)
                        if let expDate = playlist.expDate {
                            TVSettingsValueRow("Expires") {
                                Text(formattedExpiry(expDate))
                                    .foregroundStyle(isExpired(expDate) ? .red : .secondary)
                            }
                        }
                        if let maxConn = playlist.maxConnections {
                            TVSettingsValueRow("Max Connections", value: maxConn)
                        }
                        if let activeConn = playlist.activeConnections {
                            TVSettingsValueRow("Active Connections", value: activeConn)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        var tvStreamFormatSection: some View {
            if playlist.supportsStreamFormatChoice {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Playback")

                    TVOptionCycleRow(
                        title: "Live Stream Format",
                        valueLabel: playlist.streamFormat.displayName
                    ) {
                        playlist.streamFormat = playlist.streamFormat.next
                    }

                    Text(streamFormatFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 4)
                }
            }
        }

        var tvSyncSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sync")

                VStack(spacing: 2) {
                    Button {
                        playlist.syncEnabled.toggle()
                    } label: {
                        HStack(spacing: 16) {
                            Text("Sync Enabled")
                            Spacer(minLength: 0)
                            Text(playlist.syncEnabled ? "On" : "Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())

                    // Unconditional — see the iOS pane: the states worth
                    // reading were the ones that used to render as no row.
                    TVSettingsValueRow("Status") {
                        HStack(spacing: 8) {
                            if syncState == .syncing {
                                ProgressView()
                            }
                            Text(syncState.statusLabel)
                                .foregroundStyle(syncState.tint)
                        }
                    }

                    if let lastSync = syncState.lastSyncDate {
                        TVSettingsValueRow("Last Synced") {
                            Text(lastSync, style: .relative)
                        }
                    }

                    Button("Sync Now") { showSync = true }
                        .buttonStyle(TVSettingsRowButtonStyle())
                        .disabled(playlist.syncStatus == .syncing)

                    if isStalker {
                        Button("Download Full Catalog") { showFullSync = true }
                            .buttonStyle(TVSettingsRowButtonStyle())
                            .disabled(playlist.syncStatus == .syncing)
                    }
                }

                if isStalker {
                    Text("""
                    Movies and series load as you browse — nothing is prefetched. \
                    Download the full catalog to make everything available offline and \
                    searchable at once; this can take a while on large portals.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 4)
                }
            }
        }

        var tvActionsSection: some View {
            VStack(spacing: 2) {
                if isEditing {
                    Button("Done") { saveChanges() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    Button("Cancel") { cancelEditing() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                } else {
                    Button("Edit Playlist") { startEditing() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    Button("Delete Playlist") { showDeleteConfirmation = true }
                        .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
                }
            }
            .padding(.top, 12)
        }
    }

#endif
