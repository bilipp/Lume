//
//  SyncPlaylistsButton.swift
//  Lume
//
//  The Playlists page's "sync everything that's stale" control. Shared by the
//  iOS / macOS list and the tvOS pane; the caller supplies the row style.
//

import SwiftData
import SwiftUI

/// Starts a `PlaylistBatchSync` run, then turns into its progress (and a way
/// to stop it) until the run finishes.
struct SyncPlaylistsButton: View {
    let playlists: [Playlist]
    /// The selected playlist's id, already resolved through
    /// `[Playlist].activeID(for:)`.
    let activeID: String

    @Environment(\.modelContext) private var modelContext
    @State private var batch = PlaylistBatchSync.shared

    private var selection: PlaylistBatchSelection {
        .resolve(playlists.map { playlist in
            let isActive = playlist.id.uuidString == activeID
            return (playlist.id, playlist.syncState(isActive: isActive), isActive)
        })
    }

    var body: some View {
        if batch.isRunning {
            Button {
                batch.cancel()
            } label: {
                HStack(spacing: 12) {
                    ProgressView()
                    #if !os(tvOS)
                        .controlSize(.small)
                    #endif
                    Text("Syncing \(batch.position) of \(batch.total)")
                    Spacer(minLength: 0)
                    Text("Stop")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint(Text("Stops syncing playlists"))
        } else {
            let selection = selection
            Button {
                batch.start(selection, from: playlists, container: modelContext.container)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(title(for: selection))
                    Spacer(minLength: 0)
                    if case let .outOfDate(ids) = selection {
                        Text(ids.count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(selection == .none)
        }
    }

    private func title(for selection: PlaylistBatchSelection) -> LocalizedStringKey {
        switch selection {
        case .outOfDate, .none: "Sync Out-of-Date Playlists"
        case .all: "Sync All Playlists"
        }
    }
}
