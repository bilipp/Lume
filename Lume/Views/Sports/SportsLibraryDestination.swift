//
//  SportsLibraryDestination.swift
//  Lume
//
//  Search and Continue Watching retain the original catalog identities. Their
//  destination adapts classified files to the same game detail without another
//  network lookup, while ordinary library navigation stays unchanged.
//

import SwiftData
import SwiftUI

struct SportsLibraryDestination<Ordinary: View>: View {
    var catalogID: String?
    var seriesID: String?
    var scopeOverride: CatalogScope?
    @ViewBuilder var ordinary: () -> Ordinary
    @Environment(\.modelContext) private var context
    @Environment(\.contentRestriction) private var restriction
    @Environment(\.catalogScope) private var scope
    @AppStorage(SportarrSettings.enabledKey) private var enabled = false
    @State private var library = SportarrLibraryStore.shared
    @State private var games: [SportsReplayGame] = []
    @State private var loaded = false

    private var indexes: [SportarrPlaylistIndex] {
        library.indexes.values.compactMap { index in
            var subset = index
            subset.files = index.files.filter { _, record in
                catalogID.map { record.file.catalogID == $0 } ?? seriesID.map { record.file.seriesID == $0 } ?? false
            }
            return subset.files.isEmpty ? nil : subset
        }
    }

    var body: some View {
        Group {
            if !enabled || indexes.isEmpty {
                ordinary()
            } else if !loaded {
                ProgressView()
            } else if games.count == 1, let game = games.first {
                SportsReplayDetail(game: game)
            } else if games.isEmpty {
                ContentUnavailableView("No replays", systemImage: "play.rectangle")
            } else {
                SportsReplaysView(games: games, initiallyBrowseSeason: true)
            }
        }
        .task(id: "\(enabled)-\(library.revision)-\(restriction.visibilityToken)-\((scopeOverride ?? scope).token)") {
            loaded = false
            guard enabled else { games = []; return }
            let resolved = await SportarrLibraryCatalog.games(indexes: indexes, scope: scopeOverride ?? scope, restriction: restriction, container: context.container)
            guard !Task.isCancelled else { return }
            games = resolved
            loaded = true
        }
    }
}

extension SportsLibraryDestination where Ordinary == MovieDetailView {
    static func movie(_ movie: Movie, animationNamespace: Namespace.ID, scopeOverride: CatalogScope? = nil) -> Self {
        Self(catalogID: movie.id, scopeOverride: scopeOverride) {
            MovieDetailView(movie: movie, animationNamespace: animationNamespace)
        }
    }
}

extension SportsLibraryDestination where Ordinary == SeriesDetailView {
    static func series(_ series: Series, animationNamespace: Namespace.ID, scopeOverride: CatalogScope? = nil) -> Self {
        Self(seriesID: series.id, scopeOverride: scopeOverride) {
            SeriesDetailView(series: series, animationNamespace: animationNamespace)
        }
    }
}
