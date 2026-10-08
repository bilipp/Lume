//
//  HomeDownloadsRow.swift
//  Lume
//
//  The opt-in Downloads row on Home: finished downloads, newest first, across
//  every playlist. Episodes collapse into one card per series. "See All" pushes
//  the full Downloads list onto Home's stack. tvOS has no downloads, so the row
//  is never resolved there (`HomeSection.isAvailable`).
//

import SwiftData
import SwiftUI

struct HomeDownloadsRow: View {
    let seriesResume: [String: Double]
    var animationNamespace: Namespace.ID?
    let onSeeAll: () -> Void

    #if !os(tvOS)
        @Environment(\.contentRestriction) private var restriction

        // Owned by the row rather than HomeView so the queries only exist while
        // the row is switched on.
        @Query(
            filter: #Predicate<Movie> { $0.downloadStatusRaw == "completed" },
            sort: \Movie.downloadedAt,
            order: .reverse
        )
        private var movies: [Movie]

        @Query(
            filter: #Predicate<Episode> { $0.downloadStatusRaw == "completed" },
            sort: \Episode.downloadedAt,
            order: .reverse
        )
        private var episodes: [Episode]
    #endif

    var body: some View {
        #if !os(tvOS)
            let items = HomeDownloads.items(movies: movies, episodes: episodes, restriction: restriction)
            if !items.isEmpty {
                HomeRow(
                    title: "Downloads",
                    items: items,
                    seriesResume: seriesResume,
                    onPlayLive: { _ in },
                    onSeeAll: onSeeAll,
                    animationNamespace: animationNamespace
                )
            }
        #endif
    }
}

enum HomeDownloads {
    static let limit = 20

    /// Merges downloaded movies and the series of downloaded episodes into one
    /// list, newest download first. Both inputs are expected newest first, so a
    /// series takes the date of its most recent episode.
    static func items(movies: [Movie], episodes: [Episode], restriction: ContentRestriction) -> [HomeMediaItem] {
        var seen = Set<String>()
        var series: [(date: Date, item: HomeMediaItem)] = []
        for episode in episodes {
            guard let show = episode.series, seen.insert(show.id).inserted,
                  !restriction.hides(categoryID: show.categoryId) else { continue }
            series.append((episode.downloadedAt ?? .distantPast, .series(show)))
        }
        let films = movies.excludingRestricted(restriction).map {
            (date: $0.downloadedAt ?? .distantPast, item: HomeMediaItem.movie($0))
        }
        return (films + series)
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.item)
    }
}

/// Pushed by the Downloads row's "See All". A path value rather than a view
/// link, so the screen survives Home being unmounted like the detail pushes.
nonisolated struct HomeDownloadsRoute: Hashable {}

extension View {
    @ViewBuilder
    func homeDownloadsDestination() -> some View {
        #if os(tvOS)
            self
        #else
            navigationDestination(for: HomeDownloadsRoute.self) { _ in
                DownloadsView()
            }
        #endif
    }
}
