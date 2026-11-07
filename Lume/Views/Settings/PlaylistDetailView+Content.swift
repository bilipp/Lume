//
//  PlaylistDetailView+Content.swift
//  Lume
//
//  The playlist's Content switches: which kinds a sync fetches. Off means the
//  next sync skips that kind and removes what earlier syncs brought in, and
//  its tab leaves the tab bar (`Playlist.disabledContent`).
//

import SwiftData
import SwiftUI

extension Playlist {
    /// Whether a sync fetches `kind`, as a switch. Saved straight away, handed
    /// to iCloud sync so other devices follow, and reported through `onChange`
    /// so the pane can start the sync that applies it.
    ///
    /// The m3u and WebDAV fingerprints go too: a provider file that hasn't
    /// changed would otherwise skip the very import that has to apply the
    /// switch. The Xtream digests need nothing — one is only trusted while the
    /// rows it imported are all still there.
    func contentSyncBinding(
        _ kind: PlaylistTab,
        context: ModelContext,
        cloudSync: CloudSyncCoordinator?,
        onChange: @escaping @MainActor () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { self.syncs(kind) },
            set: { fetches in
                var disabled = self.disabledContent
                if fetches {
                    disabled.remove(kind)
                } else {
                    disabled.insert(kind)
                }
                guard disabled != self.disabledContent else { return }
                self.disabledContent = disabled
                try? context.save()
                M3UDigestStore.remove(playlistId: self.id)
                WebDAVDigestStore.remove(playlistId: self.id)
                Task { @MainActor in cloudSync?.reconcile() }
                onChange()
            }
        )
    }
}

extension PlaylistDetailView {
    /// Starts the sync that applies a flipped switch, unless one is running:
    /// that one reads the playlist's switches at its next phase anyway, and
    /// its `performSync` removes the rows at the end.
    func applyContentChange() {
        guard playlist.syncStatus != .syncing else { return }
        requestSync()
    }

    var contentFooter: LocalizedStringKey {
        "Content that is off is not fetched from this playlist and is removed from your library. Its tab is hidden."
    }

    #if !os(tvOS)
        var contentSection: some View {
            Section {
                ForEach(playlist.selectableContent) { kind in
                    Toggle(kind.title, isOn: playlist.contentSyncBinding(
                        kind, context: modelContext, cloudSync: cloudSync, onChange: applyContentChange
                    ))
                }
            } header: {
                Text("Content")
            } footer: {
                Text(contentFooter)
            }
        }
    #else
        var tvContentSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Content")

                VStack(spacing: 2) {
                    ForEach(playlist.selectableContent) { kind in
                        TVOptionToggleRow(title: kind.title, isOn: playlist.contentSyncBinding(
                            kind, context: modelContext, cloudSync: cloudSync, onChange: applyContentChange
                        ))
                    }
                }

                Text(contentFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 4)
            }
        }
    #endif
}
