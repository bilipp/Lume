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

        // MARK: - Recent channels

        /// The recently-watched live channels, current channel first, resolved
        /// into models for the in-player "Recent" rail. Order follows
        /// `LiveChannelHistory`; channels that no longer resolve (e.g. removed in
        /// a sync) are simply dropped.
        static func recentChannels(in context: ModelContext, defaults: UserDefaults = .standard) -> [LiveStream] {
            let ids = LiveChannelHistory.recentChannelIds(defaults: defaults)
            guard !ids.isEmpty else { return [] }
            let descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
            let byId = Dictionary(((try? context.fetch(descriptor)) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byId[$0] }
        }

        /// The titles of the programmes airing right now on the given channels,
        /// keyed by EPG channel id — a single fetch that backs the subtitle line
        /// on each card in the "Recent" rail.
        static func nowProgrammeTitles(for channels: [LiveStream], in context: ModelContext) -> [String: String] {
            let epgIds = Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty })
            guard !epgIds.isEmpty else { return [:] }
            let now = Date()
            let descriptor = FetchDescriptor<EPGListing>(
                predicate: #Predicate { epgIds.contains($0.channelId) && $0.start <= now && now < $0.end }
            )
            let listings = (try? context.fetch(descriptor)) ?? []
            return Dictionary(listings.map { ($0.channelId, $0.title) }, uniquingKeysWith: { first, _ in first })
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
    }

#endif
