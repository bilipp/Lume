//
//  WidgetLinkResolver.swift
//  Lume
//
//  Resolves the links the widgets and the tvOS Top Shelf emit —
//  `lume://play/{movie|episode|live}/{catalogId}` and
//  `lume://open/{series|movie}/{catalogId}` — to catalog content. Kept out of
//  `MainTabView` so the lookups and visibility rules are testable on their own;
//  the view only presents the result.
//

import Foundation
import SwiftData

enum WidgetLinkResolver {
    enum Target {
        case play(PlayableMedia)
        case openSeries(Series)
        case openMovie(Movie)
    }

    /// The content a widget link points at, or nil when the item is gone from
    /// the catalog, its category is hidden or restricted for this viewer, its
    /// playlist is locked by the free plan, or `link` isn't a widget link. A
    /// snapshot can outlive a resync, a profile switch and the end of a Pro
    /// subscription, so every link is re-checked here rather than trusted.
    static func resolve(
        _ link: DeepLink,
        in context: ModelContext,
        restriction: ContentRestriction,
        isPremium: Bool? = nil
    ) -> Target? {
        let locked = LockedPlaylists(context: context, isPremium: isPremium)
        switch link {
        case .playMovie, .playEpisode, .playLive:
            return playable(link, in: context, restriction: restriction, locked: locked).map(Target.play)
        case let .openSeries(id):
            guard !locked.owns(id),
                  let series = first(Series.self, #Predicate { $0.id == id }, in: context),
                  !restriction.hides(categoryID: series.categoryId) else { return nil }
            return .openSeries(series)
        case let .openMovie(id):
            guard !locked.owns(id),
                  let movie = first(Movie.self, #Predicate { $0.id == id }, in: context),
                  !restriction.hides(categoryID: movie.categoryId) else { return nil }
            return .openMovie(movie)
        case .movie, .series, .resume, .downloads, .cloudPair:
            return nil
        }
    }

    private static func playable(
        _ link: DeepLink,
        in context: ModelContext,
        restriction: ContentRestriction,
        locked: LockedPlaylists
    ) -> PlayableMedia? {
        switch link {
        case let .playMovie(id):
            guard !locked.owns(id),
                  let movie = first(Movie.self, #Predicate { $0.id == id }, in: context),
                  !restriction.hides(categoryID: movie.categoryId),
                  let playlist = PlaylistOwner.playlist(forPrefixedID: id, in: context) else { return nil }
            return PlayableMedia.from(movie: movie, playlist: playlist)
        case let .playEpisode(id):
            // Episodes carry no category of their own; the show's decides.
            guard let episode = first(Episode.self, #Predicate { $0.id == id }, in: context),
                  let series = episode.series,
                  !locked.owns(series.id),
                  !restriction.hides(categoryID: series.categoryId),
                  let playlist = PlaylistOwner.playlist(forPrefixedID: series.id, in: context) else { return nil }
            return PlayableMedia.from(episode: episode, playlist: playlist)
        case let .playLive(id):
            guard !locked.owns(id),
                  let stream = first(LiveStream.self, #Predicate { $0.id == id && $0.isHidden == false }, in: context),
                  !restriction.hides(categoryID: stream.categoryId),
                  let playlist = PlaylistOwner.playlist(forPrefixedID: id, in: context) else { return nil }
            return PlayableMedia.from(stream: stream, playlist: playlist)
        default:
            return nil
        }
    }

    /// The playlists the free plan locks, for checking a link's catalog id
    /// against. Fetched only without Pro, where every playlist is in reach.
    private struct LockedPlaylists {
        let playlists: [Playlist]
        let isPremium: Bool

        init(context: ModelContext, isPremium: Bool?) {
            self.isPremium = PremiumManager.isPremium(isPremium)
            playlists = self.isPremium ? [] : (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        }

        /// Whether the catalog row `id` came from a locked playlist.
        func owns(_ id: String) -> Bool {
            playlists.isLocked(contentID: id, isPremium: isPremium)
        }
    }

    private static func first<Model: PersistentModel>(
        _: Model.Type,
        _ predicate: Predicate<Model>,
        in context: ModelContext
    ) -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
