//
//  WatchProviderBrowse.swift
//  Lume
//
//  "Browse by Provider" on the Movies and Series tabs. A title's streaming
//  services come from TMDB (the `flatrate` offers for the user's region, stored
//  on `Movie`/`Series` as `watchProviderIdsRaw`), so these surfaces cut across
//  the provider categories — mirroring the genre browse. Only the services the
//  user selected in Settings, and that actually have content, are shown.
//

import SwiftData
import SwiftUI

// MARK: - Derivation

/// Upper bound on the fetch that enumerates which providers appear in a
/// playlist. Matches `GenreDerivation`'s sampling trade-off: the provider
/// vocabulary is tiny, so a bounded sample surfaces every present provider while
/// keeping the derivation cheap on large libraries.
private let providerSampleLimit = 5000

enum WatchProviderDerivation {
    /// The selected providers that actually have movies in the active playlist,
    /// resolved to catalog rows (for name + logo) and ordered by display
    /// priority. Empty when nothing is selected or no enriched titles match.
    static func movieProviders(
        in context: ModelContext,
        playlistPrefix: String,
        restriction: ContentRestriction,
        selected: Set<Int>
    ) -> [WatchProvider] {
        guard !selected.isEmpty else { return [] }
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.watchProviderIdsRaw != nil })
        descriptor.fetchLimit = providerSampleLimit
        let movies = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.id.hasPrefix(playlistPrefix) }
            .excludingRestricted(restriction)
        return resolve(present: presentIDs(in: movies.map(\.watchProviderIdsRaw)), selected: selected, in: context)
    }

    /// Series counterpart of ``movieProviders(in:playlistPrefix:restriction:selected:)``.
    static func seriesProviders(
        in context: ModelContext,
        playlistPrefix: String,
        restriction: ContentRestriction,
        selected: Set<Int>
    ) -> [WatchProvider] {
        guard !selected.isEmpty else { return [] }
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.watchProviderIdsRaw != nil })
        descriptor.fetchLimit = providerSampleLimit
        let series = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.id.hasPrefix(playlistPrefix) }
            .excludingRestricted(restriction)
        return resolve(present: presentIDs(in: series.map(\.watchProviderIdsRaw)), selected: selected, in: context)
    }

    private static func presentIDs(in raws: [String?]) -> Set<Int> {
        var ids = Set<Int>()
        for raw in raws {
            ids.formUnion(WatchProviderIDs.decode(raw))
        }
        return ids
    }

    /// The catalog rows for the selected providers present in the library,
    /// ordered by TMDB display priority then name.
    private static func resolve(present: Set<Int>, selected: Set<Int>, in context: ModelContext) -> [WatchProvider] {
        let show = present.intersection(selected)
        guard !show.isEmpty else { return [] }
        let descriptor = FetchDescriptor<WatchProvider>(
            sortBy: [SortDescriptor(\.displayPriority), SortDescriptor(\.name)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { show.contains($0.id) }
    }
}

// MARK: - Browse-by-provider section

/// A tile grid of the user's selected providers that have content in the active
/// playlist. Each tile shows the provider's logo and navigates to its full grid.
///
/// Like `GenreGridSection`, the owning view derives the providers and renders
/// this only when non-empty — a view that collapses to nothing never receives
/// `.task`/`.onAppear`, so the derivation must live on the always-present host.
struct WatchProviderGridSection: View {
    let providers: [WatchProvider]
    let type: CategoryType

    private let columns = [GridItem(.adaptive(minimum: CategoryTileMetrics.minimum), spacing: CategoryTileMetrics.spacing)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse by Provider")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: CategoryTileMetrics.spacing) {
                ForEach(providers) { provider in
                    NavigationLink(value: WatchProviderSelection(providerId: provider.id, name: provider.name, type: type)) {
                        WatchProviderTile(provider: provider)
                    }
                    .posterCardButtonStyle()
                }
            }
            .padding(.horizontal)
        }
    }
}

/// A name tile fronted by the provider's logo. Mirrors `CategoryTile`'s flat
/// material look and tvOS focus brighten so it sits cleanly beside the genre
/// and category tiles.
struct WatchProviderTile: View {
    let provider: WatchProvider

    #if os(tvOS)
        @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: TMDBClient.providerLogoURL(provider.logoPath), maxPixelSize: logoSize * 2) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                default:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.gray.opacity(0.3))
                        .overlay { Image(systemName: "play.tv").foregroundStyle(.secondary) }
                }
            }
            .frame(width: logoSize, height: logoSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(provider.name)
                .font(CategoryTileMetrics.font)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(foreground)

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CategoryTileMetrics.height)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: CategoryTileMetrics.cornerRadius, style: .continuous))
        #if os(tvOS)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        #endif
    }

    private var logoSize: CGFloat {
        #if os(tvOS)
            56
        #else
            36
        #endif
    }

    private var foreground: Color {
        #if os(tvOS)
            isFocused ? .black : .primary
        #else
            .primary
        #endif
    }

    @ViewBuilder
    private var background: some View {
        #if os(tvOS)
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.white.opacity(isFocused ? 1 : 0))
        #else
            Rectangle().fill(.ultraThinMaterial)
        #endif
    }
}

// MARK: - Provider detail grids

/// The full grid of movies available on a provider. The fetch narrows to
/// candidate rows in SQLite via the sentinel token (`|8|`), then re-filters to
/// exact id matches in memory — the same shape as the genre grids.
struct MovieWatchProviderView: View {
    let providerId: Int
    let name: String
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var movies: [Movie] = []

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    var body: some View {
        CategoryContentGrid(
            title: name,
            items: movies,
            animationNamespace: animationNamespace,
            emptyTitle: "No Movies",
            emptyIcon: "film.stack",
            emptyDescription: "No movies on this provider yet",
            sortRaw: $contentSortRaw,
            card: { MovieCardView(movie: $0) }
        )
        .task(id: contentSortRaw) {
            let token = WatchProviderIDs.queryToken(for: providerId)
            let descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { ($0.watchProviderIdsRaw?.localizedStandardContains(token)) ?? false },
                sortBy: contentSort.movieDescriptors
            )
            let id = providerId
            movies = ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { $0.id.hasPrefix(playlistPrefix) && WatchProviderIDs.contains($0.watchProviderIdsRaw, id: id) }
                .excludingRestricted(restriction)
        }
    }
}

/// The full grid of series available on a provider.
struct SeriesWatchProviderView: View {
    let providerId: Int
    let name: String
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @AppStorage(SortStorageKey.seriesContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @State private var series: [Series] = []

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    var body: some View {
        CategoryContentGrid(
            title: name,
            items: series,
            animationNamespace: animationNamespace,
            emptyTitle: "No Series",
            emptyIcon: "tv.fill",
            emptyDescription: "No series on this provider yet",
            sortRaw: $contentSortRaw,
            card: { SeriesCardView(series: $0) }
        )
        .task(id: contentSortRaw) {
            let token = WatchProviderIDs.queryToken(for: providerId)
            let descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { ($0.watchProviderIdsRaw?.localizedStandardContains(token)) ?? false },
                sortBy: contentSort.seriesDescriptors
            )
            let id = providerId
            series = ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { $0.id.hasPrefix(playlistPrefix) && WatchProviderIDs.contains($0.watchProviderIdsRaw, id: id) }
                .excludingRestricted(restriction)
        }
    }
}
