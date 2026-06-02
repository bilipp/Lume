//
//  TVPlayerContent.swift
//  Lume
//
//  SwiftData lookups that back the tvOS in-player overlay. Given the value-type
//  `PlayableMedia` the player knows about, these resolve the underlying model
//  objects (episode + sibling episodes, movie, live stream + EPG) so the
//  overlay can render the episode rail, the information panel and the EPG
//  caption, and build a `PlayableMedia` for a newly-picked episode.
//

#if os(tvOS)

    import Foundation
    import SwiftData

    enum TVPlayerContent {
        // MARK: - Model lookups

        static func episode(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Episode? {
            guard case let .episode(id) = ref else { return nil }
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        static func movie(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Movie? {
            guard case let .movie(id) = ref else { return nil }
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        static func liveStream(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> LiveStream? {
            guard case let .live(id) = ref else { return nil }
            var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        // MARK: - Episodes

        /// Episodes of the given episode's season, ordered by episode number —
        /// the content of the in-player episode rail.
        static func seasonEpisodes(for episode: Episode) -> [Episode] {
            guard let series = episode.series else { return [episode] }
            return series.episodes
                .filter { $0.seasonNum == episode.seasonNum }
                .sorted { $0.episodeNum < $1.episodeNum }
        }

        /// The playlist that owns a series, mirroring the detail screen's logic
        /// (prefix match on the playlist UUID, falling back to the first one).
        static func playlist(for series: Series?, in context: ModelContext) -> Playlist? {
            let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            guard let series else { return playlists.first }
            return playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
        }

        // MARK: - EPG

        /// Upcoming/ongoing EPG listings for a channel, soonest first.
        static func epgListings(channelId: String?, in context: ModelContext) -> [EPGListing] {
            guard let channelId, !channelId.isEmpty else { return [] }
            let now = Date()
            let descriptor = FetchDescriptor<EPGListing>(
                predicate: #Predicate { $0.channelId == channelId && $0.end > now },
                sortBy: [SortDescriptor(\.start)]
            )
            return (try? context.fetch(descriptor)) ?? []
        }

        // MARK: - Channel switching

        /// The playlist that owns a live stream. Stream `id`s are prefixed with
        /// the owning playlist's UUID at sync time (see `ContentSyncManager`),
        /// mirroring the series-playlist resolution above.
        static func playlist(for stream: LiveStream, in context: ModelContext) -> Playlist? {
            let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            return playlists.first { stream.id.hasPrefix($0.id.uuidString) } ?? playlists.first
        }

        /// The playable channel `offset` positions away from `media` within its
        /// category, honouring the live-content sort the browser uses so the
        /// order matches the channel list. `offset` is `+1` for the next channel
        /// and `-1` for the previous; the list wraps at the category's ends so
        /// surfing never dead-ends. Returns `nil` when `media` isn't a resolvable
        /// live stream or its category holds a single channel.
        static func adjacentLiveMedia(
            for media: PlayableMedia,
            offset: Int,
            sort: ContentSortOption,
            in context: ModelContext
        ) -> PlayableMedia? {
            guard let current = liveStream(for: media.contentRef, in: context),
                  let categoryId = current.categoryId else { return nil }
            let descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.categoryId == categoryId },
                sortBy: sort.liveStreamDescriptors
            )
            guard let streams = try? context.fetch(descriptor), streams.count > 1,
                  let index = streams.firstIndex(where: { $0.id == current.id }) else { return nil }
            let target = streams[(index + offset + streams.count) % streams.count]
            guard let playlist = playlist(for: target, in: context) else { return nil }
            return PlayableMedia.from(stream: target, playlist: playlist)
        }
    }

#endif
