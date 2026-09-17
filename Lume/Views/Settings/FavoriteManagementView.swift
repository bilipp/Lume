//
//  FavoriteManagementView.swift
//  Lume
//
//  Reorder and unfavorite the active playlist's favorites — live channels,
//  movies and series — in a single cross-type list. Reached by drilling into
//  "Favorites" from ContentManagementView. The arrangement persists on each
//  model's `favoriteOrder`, stamped densely across the whole list so a movie can
//  sit above a channel, and survives re-syncs (it also rides iCloud via
//  UserContentState). Like the other Content Management screens, this view relies
//  on the ambient NavigationStack and never creates its own.
//

import SwiftData
import SwiftUI

/// Navigation marker for the favorites-reorder drill-in from Content Management.
/// Carries no payload — the view reads the active playlist itself.
struct FavoritesRoute: Hashable {}

/// One row in the unified favorites list. A value-type wrapper over any of the
/// three favoritable models, erased to `any FavoriteOrderable` so a single dense
/// `favoriteOrder` stamp interleaves the types.
struct FavoriteEntry: Identifiable, ReorderableRowItem {
    enum Kind {
        case live, movie, series

        /// Fallback grouping for favorites that have never been reordered
        /// (`favoriteOrder == nil`): channels, then movies, then series.
        var sortRank: Int {
            switch self {
            case .live: 0
            case .movie: 1
            case .series: 2
            }
        }

        var label: String {
            switch self {
            case .live: String(localized: "Live TV")
            case .movie: String(localized: "Movie")
            case .series: String(localized: "Series")
            }
        }

        var placeholderSymbol: String {
            switch self {
            case .live: "antenna.radiowaves.left.and.right"
            case .movie: "film"
            case .series: "tv"
            }
        }
    }

    let id: String
    let model: any FavoriteOrderable
    let title: String
    let iconURL: URL?
    let kind: Kind
    let favoriteOrder: Int?
    let providerNum: Int
}

struct FavoriteManagementView: View {
    @Query private var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

    /// Each type is fetched and sorted by its own `favoriteOrder` (nil-first, then
    /// the provider order); the three are merged and re-sorted in-memory into the
    /// cross-type arrangement. Favorites are few, so the in-memory pass is cheap.
    @Query(
        filter: #Predicate<LiveStream> { $0.isFavorite },
        sort: [SortDescriptor(\LiveStream.favoriteOrder), SortDescriptor(\LiveStream.num), SortDescriptor(\LiveStream.name)]
    ) private var favoriteChannels: [LiveStream]

    @Query(
        filter: #Predicate<Movie> { $0.isFavorite },
        sort: [SortDescriptor(\Movie.favoriteOrder), SortDescriptor(\Movie.num), SortDescriptor(\Movie.name)]
    ) private var favoriteMovies: [Movie]

    @Query(
        filter: #Predicate<Series> { $0.isFavorite },
        sort: [SortDescriptor(\Series.favoriteOrder), SortDescriptor(\Series.num), SortDescriptor(\Series.name)]
    ) private var favoriteSeries: [Series]

    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// Every favorite of the active playlist, merged across types and ordered by
    /// the cross-type `favoriteOrder`. Untouched favorites (nil order) fall
    /// through to a stable type/provider grouping.
    private var favorites: [FavoriteEntry] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"

        var entries: [FavoriteEntry] = []
        for stream in favoriteChannels where stream.id.hasPrefix(prefix) {
            entries.append(FavoriteEntry(
                id: stream.id, model: stream, title: stream.name,
                iconURL: URL(string: stream.streamIcon ?? ""), kind: .live,
                favoriteOrder: stream.favoriteOrder, providerNum: stream.num
            ))
        }
        for movie in favoriteMovies where movie.id.hasPrefix(prefix) {
            entries.append(FavoriteEntry(
                id: movie.id, model: movie, title: movie.name,
                iconURL: URL(string: movie.streamIcon ?? ""), kind: .movie,
                favoriteOrder: movie.favoriteOrder, providerNum: movie.num
            ))
        }
        for series in favoriteSeries where series.id.hasPrefix(prefix) {
            entries.append(FavoriteEntry(
                id: series.id, model: series, title: series.name,
                iconURL: URL(string: series.cover ?? ""), kind: .series,
                favoriteOrder: series.favoriteOrder, providerNum: series.num
            ))
        }

        return entries.sorted { lhs, rhs in
            (lhs.favoriteOrder ?? Int.max, lhs.kind.sortRank, lhs.providerNum, lhs.title)
                < (rhs.favoriteOrder ?? Int.max, rhs.kind.sortRank, rhs.providerNum, rhs.title)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        ContentOrganizer.reorderFavorites(favorites.map(\.model), from: source, to: destination)
    }

    private func remove(_ entry: FavoriteEntry) {
        MediaFavorites.clearFavoriteState(entry.model)
    }

    private func reset() {
        ContentOrganizer.resetFavoriteOrder(favorites.map(\.model))
    }

    // MARK: - Platform bodies

    #if os(tvOS)
        /// True while a row is lifted for placement — disables Reset so it can't
        /// steal focus mid-move.
        @State private var isReordering = false

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("Favorites")
                            .font(.system(size: 34, weight: .bold))
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                        HStack {
                            TVSettingsSectionLabel("All Favorites")
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
                            Text("No favorites yet. Mark channels, movies, or series as favorites to manage their order here.")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        } else {
                            TVReorderableContentList(
                                items: favorites,
                                title: { "\($0.title) · \($0.kind.label)" },
                                isHidden: { _ in false },
                                onToggleHidden: { remove($0) },
                                onCommitOrder: { ContentOrganizer.commitFavoriteOrder($0.map(\.model)) },
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
                        Text("No favorites yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favorites) { entry in
                            FavoriteRow(entry: entry, onRemove: { remove(entry) })
                        }
                        .onMove(perform: move)
                    }
                } footer: {
                    Text("Drag to reorder your favorites across channels, movies, and series — a movie can sit above a channel. Tap the heart to remove one. Reset restores the default order.")
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
    private struct FavoriteRow: View {
        let entry: FavoriteEntry
        let onRemove: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Button(action: onRemove) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(entry.title) from favorites")

                CachedAsyncImage(url: entry.iconURL, maxPixelSize: 44) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay {
                                Image(systemName: entry.kind.placeholderSymbol)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .lineLimit(1)
                    Text(entry.kind.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }
#endif

#Preview("Favorites") {
    NavigationStack {
        FavoriteManagementView()
    }
    .modelContainer(previewContainer())
}
