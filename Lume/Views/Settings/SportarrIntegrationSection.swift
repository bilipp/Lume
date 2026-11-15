//
//  SportarrIntegrationSection.swift
//  Lume
//
//  The only Sportarr control. Enabling asks the existing import to collect IDs;
//  disabling cancels queued lookups and leaves original catalog data intact.
//

import SwiftData
import SwiftUI

struct SportarrIntegrationSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.catalogScope) private var scope
    @Environment(\.contentRestriction) private var restriction
    @AppStorage(SportarrSettings.enabledKey) private var enabled = false
    @State private var library = SportarrLibraryStore.shared
    @State private var visibleCount = 0
    @State private var refresh: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(tvOS)
                TVOptionToggleRow(title: "Sportarr integration", isOn: $enabled)
            #else
                Toggle("Sportarr integration", isOn: $enabled)
            #endif
            Text("Looks up identified sports files on sportarr.net and shows them in Replays.")
                .font(.footnote).foregroundStyle(.secondary)
            if enabled {
                if library.isUnavailable {
                    Text("Sportarr is not responding. Replays already found still work.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("\(visibleCount) replays found")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(enabled)-\(library.revision)-\(scope.token)-\(restriction.visibilityToken)") {
            guard enabled else { visibleCount = 0; return }
            let games = await SportarrLibraryCatalog.games(indexes: Array(library.indexes.values), scope: scope, restriction: restriction, container: context.container)
            guard !Task.isCancelled else { return }
            visibleCount = games.flatMap(\.libraryFiles).count
        }
        .onChange(of: enabled) { _, value in
            refresh?.cancel()
            refresh = Task {
                await SportarrSyncCoordinator.shared.settingsChanged()
                guard value else { return }
                let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
                let manager = ContentSyncManager(modelContainer: context.container)
                for playlist in playlists where scope.playlistIDs.contains(playlist.id) && playlist.syncStatus != .syncing {
                    guard !Task.isCancelled, enabled else { return }
                    switch playlist.sourceType {
                    case .jellyfin, .emby, .silo, .webdav: try? await manager.syncPlaylist(playlist)
                    default: break
                    }
                }
            }
        }
    }
}
