//
//  FavoriteChannelManagementView.swift
//  Lume
//
//  Reorder and unfavorite the active playlist's favorite live channels. Reached
//  by drilling into "Favorites" from ContentManagementView's Live TV section.
//  The arrangement persists on `LiveStream.favoriteOrder` (independent of the
//  per-category `customOrder`), so it survives re-syncs and is inherently
//  per-playlist. Like the other Content Management screens, this view relies on
//  the ambient NavigationStack and never creates its own.
//

import SwiftData
import SwiftUI

/// Navigation marker for the favorites-reorder drill-in from Content Management.
/// Carries no payload — the view reads the active playlist itself.
struct FavoriteChannelsRoute: Hashable {}

struct FavoriteChannelManagementView: View {
    @Query private var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

    /// Every favorite channel across all playlists, in the Favorites ordering
    /// convention (`favoriteOrder` first, then the provider order). Scoped to the
    /// active playlist in-memory — the predicate can't be parameterised on the
    /// playlist-prefixed id.
    @Query private var allFavorites: [LiveStream]

    init() {
        _allFavorites = Query(
            filter: #Predicate<LiveStream> { $0.isFavorite },
            sort: [
                SortDescriptor(\LiveStream.favoriteOrder),
                SortDescriptor(\LiveStream.num),
                SortDescriptor(\LiveStream.name)
            ]
        )
    }

    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    private var favorites: [LiveStream] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return allFavorites.filter { $0.id.hasPrefix(prefix) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        ContentOrganizer.reorderFavorites(favorites, from: source, to: destination)
    }

    private func reset() {
        ContentOrganizer.resetFavoriteOrder(favorites)
    }

    // MARK: - Platform bodies

    #if os(tvOS)
        /// True while a channel is lifted for placement — disables Reset so it
        /// can't steal focus mid-move.
        @State private var isReordering = false

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("Favorites")
                            .font(.system(size: 34, weight: .bold))
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                        HStack {
                            TVSettingsSectionLabel("Favorite Channels")
                            Spacer()
                            Button("Reset") { reset() }
                                .buttonStyle(TVSettingsActionButtonStyle())
                                .disabled(favorites.isEmpty || isReordering)
                        }

                        if isReordering {
                            Text("Move up or down to position, then select to place. Press Menu to cancel.")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        }

                        if favorites.isEmpty {
                            Text("No favorite channels yet. Mark channels as favorites to manage their order here.")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        } else {
                            TVReorderableContentList(
                                items: favorites,
                                title: { $0.name },
                                isHidden: { _ in false },
                                onToggleHidden: { $0.isFavorite = false; $0.favoriteOrder = nil },
                                onCommitOrder: { ContentOrganizer.commitFavoriteOrder($0) },
                                isReordering: $isReordering,
                                scrollProxy: proxy,
                                toggleImage: { _ in "heart.fill" },
                                toggleAccessibility: { _, title in "Remove \(title) from Favorites" }
                            )
                        }
                    }
                    .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 72)
                }
            }
            .tvSettingsBackground()
        }
    #else
        var body: some View {
            List {
                Section {
                    if favorites.isEmpty {
                        Text("No favorite channels yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favorites) { stream in
                            FavoriteChannelRow(
                                title: stream.name,
                                iconURL: URL(string: stream.streamIcon ?? ""),
                                onRemove: { stream.isFavorite = false; stream.favoriteOrder = nil }
                            )
                        }
                        .onMove(perform: move)
                    }
                } footer: {
                    Text("Drag to reorder your favorite channels — this sets the order shown in the Favorites category. Tap the heart to remove one. Reset restores the provider's order.")
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            #endif
            .navigationTitle("Favorites")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            EditButton()
                        }
                    #endif
                    ToolbarItem(placement: .automatic) {
                        Button("Reset", role: .destructive) { reset() }
                            .disabled(favorites.isEmpty)
                    }
                }
        }
    #endif
}

// MARK: - iOS / macOS row

#if !os(tvOS)
    private struct FavoriteChannelRow: View {
        let title: String
        let iconURL: URL?
        let onRemove: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Button(action: onRemove) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(title) from favorites")

                CachedAsyncImage(url: iconURL, maxPixelSize: 44) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(title)
                    .lineLimit(1)

                Spacer()
            }
        }
    }
#endif

#Preview("Favorite Channels") {
    NavigationStack {
        FavoriteChannelManagementView()
    }
    .modelContainer(previewContainer())
}
