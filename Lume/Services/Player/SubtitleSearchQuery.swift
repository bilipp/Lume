//
//  SubtitleSearchQuery.swift
//  Lume
//
//  Resolves the OpenSubtitles lookup key for the content currently playing.
//
//  Mirrors `IntroSkipResolver`: the player view owns the SwiftData fetch and
//  hands a plain value down, so the search sheet never touches the catalog
//  models. Live channels resolve to `nil` — OpenSubtitles indexes films and
//  episodes, and a live stream has neither an id nor a stable title to match on.
//

import Foundation
import SwiftData

enum SubtitleSearchQuery {
    /// The OpenSubtitles query for `ref`, or `nil` when the content isn't
    /// something the catalogue indexes (a live channel) or can't be resolved.
    ///
    /// Ids beat text every time — a TMDB/IMDb id pins the exact feature, while a
    /// title match drags in remakes and same-named releases — so both are sent
    /// when known and the title only rides along as a fallback for titles the
    /// library hasn't enriched yet.
    static func resolve(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> OpenSubtitlesQuery? {
        switch ref {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? context.fetch(descriptor).first else { return nil }
            return OpenSubtitlesQuery(
                text: movie.name,
                imdbId: movie.imdbId,
                tmdbId: movie.tmdbId
            )

        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { return nil }
            let series = episode.series
            return OpenSubtitlesQuery(
                // The series name, not the episode title: OpenSubtitles matches
                // episodes under their show plus season/episode numbers.
                text: series?.name ?? episode.title,
                parentImdbId: series?.imdbId,
                parentTmdbId: series?.tmdbId,
                season: episode.seasonNum,
                episode: episode.episodeNum
            )

        case .live:
            return nil
        }
    }
}
