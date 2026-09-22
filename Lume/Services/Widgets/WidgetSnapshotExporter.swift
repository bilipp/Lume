//
//  WidgetSnapshotExporter.swift
//  Lume
//
//  Builds the `WidgetSnapshot` the widgets and the tvOS Top Shelf render, and
//  writes it to the shared App Group container. Extensions never query the
//  catalog themselves — SwiftData stays app-only and the extension reads a
//  small precomputed file instead (the reliable pattern for widget data).
//
//  Runs off the main actor on its own `ModelContext`, mirroring the Home
//  screen's rails: Recently Watched (resumable movies + series), Favorites
//  (unified `favoriteOrder`), and now/next EPG for favorite channels.
//

import Foundation
import SwiftData
#if os(iOS) || os(macOS)
    import WidgetKit
#endif

enum WidgetSnapshotExporter {
    private static let continueWatchingLimit = 10
    private static let favoritesLimit = 12
    private static let onNowLimit = 8

    /// Exports a fresh snapshot for the active playlist/profile and reloads the
    /// widget timelines.
    nonisolated static func export(container: ModelContainer, isChildProfile: Bool, now: Date = Date()) {
        let storedID = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? ""
        let snapshot = makeSnapshot(
            container: container,
            storedPlaylistID: storedID,
            isChildProfile: isChildProfile,
            now: now
        )
        try? WidgetDataStore.save(snapshot)
        #if os(iOS) || os(macOS)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Builds the snapshot for the active playlist. Restricted categories stay
    /// out of the snapshot while a child profile is active — a widget must not
    /// leak hidden content. Internal (not private) so tests can build snapshots
    /// without touching the App Group container.
    nonisolated static func makeSnapshot(
        container: ModelContainer,
        storedPlaylistID: String,
        isChildProfile: Bool,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let context = ModelContext(container)
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        guard let playlist = playlists.active(for: storedPlaylistID) else {
            var empty = WidgetSnapshot.empty
            empty.generatedAt = now
            return empty
        }

        let playlistPrefix = "\(playlist.id.uuidString)-"
        let restriction = ContentRestriction(
            isActive: isChildProfile,
            restrictedCategoryIDs: isChildProfile ? restrictedCategoryIDs(in: context) : []
        )

        return WidgetSnapshot(
            generatedAt: now,
            continueWatching: continueWatching(in: context, prefix: playlistPrefix, restriction: restriction),
            favorites: favorites(in: context, prefix: playlistPrefix, restriction: restriction),
            onNow: onNow(in: context, container: container, prefix: playlistPrefix, restriction: restriction, now: now)
        )
    }

    private nonisolated static func restrictedCategoryIDs(in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.isRestricted })
        let categories = (try? context.fetch(descriptor)) ?? []
        return Set(categories.map(\.id))
    }

    // MARK: - Continue Watching

    /// Resumable titles, most recently watched first: partially-watched movies
    /// plus the in-progress episode of recently-watched series (the same resume
    /// resolution as the Home rail, see `HomeMediaItem.progress`).
    private nonisolated static func continueWatching(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [WidgetMediaItem] {
        let entries = resumableMovies(in: context, prefix: prefix, restriction: restriction)
            + resumableEpisodes(in: context, prefix: prefix, restriction: restriction)
        return entries
            .sorted { $0.lastWatched > $1.lastWatched }
            .prefix(continueWatchingLimit)
            .map(\.item)
    }

    private nonisolated static func resumableMovies(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [(lastWatched: Date, item: WidgetMediaItem)] {
        var entries: [(lastWatched: Date, item: WidgetMediaItem)] = []

        var movieDescriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.lastWatchedDate != nil && !$0.isWatched && $0.watchProgress > 0 },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        movieDescriptor.fetchLimit = 30
        let movies = (try? context.fetch(movieDescriptor)) ?? []
        for movie in movies where movie.id.hasPrefix(prefix) && !restriction.hides(categoryID: movie.categoryId) {
            guard let lastWatched = movie.lastWatchedDate,
                  let deepLink = WidgetDeepLink.play(kind: .movie, id: movie.id) else { continue }
            var progress: Double?
            if let duration = movie.durationSecs, duration > 0 {
                progress = min(movie.watchProgress / Double(duration), 1)
            }
            entries.append((lastWatched, WidgetMediaItem(
                id: "movie-\(movie.id)",
                kind: .movie,
                title: movie.name,
                subtitle: movie.releaseDate,
                imageURL: URL(string: movie.streamIcon ?? ""),
                progress: progress,
                deepLink: deepLink
            )))
        }
        return entries
    }

    private nonisolated static func resumableEpisodes(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [(lastWatched: Date, item: WidgetMediaItem)] {
        var entries: [(lastWatched: Date, item: WidgetMediaItem)] = []

        var seriesDescriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        seriesDescriptor.fetchLimit = 30
        let series = (try? context.fetch(seriesDescriptor)) ?? []
        for show in series where show.id.hasPrefix(prefix) && !restriction.hides(categoryID: show.categoryId) {
            let inProgress = show.episodes
                .filter { $0.watchProgress > 0 && !$0.isWatched }
                .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            guard let episode = inProgress.first,
                  let lastWatched = show.lastWatchedDate,
                  let deepLink = WidgetDeepLink.play(kind: .episode, id: episode.id) else { continue }
            var progress: Double?
            if let duration = episode.durationSecs, duration > 0 {
                progress = min(episode.watchProgress / Double(duration), 1)
            }
            entries.append((lastWatched, WidgetMediaItem(
                id: "episode-\(episode.id)",
                kind: .episode,
                title: show.name,
                subtitle: "S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)",
                imageURL: URL(string: show.cover ?? episode.movieImage ?? ""),
                progress: progress,
                deepLink: deepLink
            )))
        }
        return entries
    }

    // MARK: - Favorites

    /// Favorite movies, series and channels interleaved by the user's unified
    /// `favoriteOrder` (nil orders last, then alphabetical — same as Home).
    private nonisolated static func favorites(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [WidgetMediaItem] {
        var entries: [(order: Int, item: WidgetMediaItem)] = []

        let movies = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.isFavorite }))) ?? []
        for movie in movies where movie.id.hasPrefix(prefix) && !restriction.hides(categoryID: movie.categoryId) {
            guard let deepLink = WidgetDeepLink.play(kind: .movie, id: movie.id) else { continue }
            entries.append((movie.favoriteOrder ?? Int.max, WidgetMediaItem(
                id: "movie-\(movie.id)",
                kind: .movie,
                title: movie.name,
                subtitle: nil,
                imageURL: URL(string: movie.streamIcon ?? ""),
                progress: nil,
                deepLink: deepLink
            )))
        }

        let series = (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.isFavorite }))) ?? []
        for show in series where show.id.hasPrefix(prefix) && !restriction.hides(categoryID: show.categoryId) {
            guard let deepLink = WidgetDeepLink.openSeries(id: show.id) else { continue }
            entries.append((show.favoriteOrder ?? Int.max, WidgetMediaItem(
                id: "series-\(show.id)",
                kind: .series,
                title: show.name,
                subtitle: nil,
                imageURL: URL(string: show.cover ?? ""),
                progress: nil,
                deepLink: deepLink
            )))
        }

        let streams = (try? context.fetch(FetchDescriptor<LiveStream>(predicate: #Predicate { $0.isFavorite }))) ?? []
        for stream in streams where stream.id.hasPrefix(prefix) && !restriction.hides(categoryID: stream.categoryId) {
            guard let deepLink = WidgetDeepLink.play(kind: .live, id: stream.id) else { continue }
            entries.append((stream.favoriteOrder ?? Int.max, WidgetMediaItem(
                id: "live-\(stream.id)",
                kind: .live,
                title: stream.name,
                subtitle: nil,
                imageURL: URL(string: stream.streamIcon ?? ""),
                progress: nil,
                deepLink: deepLink
            )))
        }

        return entries
            .sorted { ($0.order, $0.item.title) < ($1.order, $1.item.title) }
            .prefix(favoritesLimit)
            .map(\.item)
    }

    // MARK: - On Now

    /// Now/next programmes for favorite channels, resolved through the same
    /// indexed EPG fetch the channel list uses (`ChannelEPGLoader`). Channels
    /// without guide data still appear — the widget shows them logo-only.
    private nonisolated static func onNow(
        in context: ModelContext,
        container: ModelContainer,
        prefix: String,
        restriction: ContentRestriction,
        now: Date
    ) -> [WidgetChannelNow] {
        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        let streams = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.id.hasPrefix(prefix) && !restriction.hides(categoryID: $0.categoryId) }
            .prefix(onNowLimit)

        let channelIds = streams.compactMap(\.epgChannelId)
        let guide = ChannelEPGLoader.load(container: container, channelIds: channelIds, now: now)

        return streams.compactMap { stream in
            guard let deepLink = WidgetDeepLink.play(kind: .live, id: stream.id) else { return nil }
            let epg = stream.epgChannelId.flatMap { guide[$0] }
            return WidgetChannelNow(
                id: stream.id,
                channelName: stream.name,
                logoURL: URL(string: stream.streamIcon ?? ""),
                nowTitle: epg?.current?.title,
                nowStart: epg?.current?.start,
                nowEnd: epg?.current?.end,
                nextTitle: epg?.next?.title,
                nextStart: epg?.next?.start,
                deepLink: deepLink
            )
        }
    }
}
