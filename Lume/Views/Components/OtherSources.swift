//
//  OtherSources.swift
//  Lume
//
//  Resolves other entries of the *same* title (matched by TMDB id) within the
//  same playlist — e.g. an alternate quality or language stream. Shared by the
//  movie and series detail screens (iOS, macOS and tvOS) so the "Other Sources"
//  row behaves identically everywhere.
//

import Foundation
import SwiftData

enum OtherSources {
    /// Other `Movie` entries that share `movie`'s TMDB id and playlist, excluding
    /// `movie` itself. Empty when the movie has no TMDB id.
    static func resolve(for movie: Movie, in context: ModelContext) -> [HomeMediaItem] {
        guard let tmdbId = movie.tmdbId else { return [] }
        let prefix = movie.id.components(separatedBy: "-movie-").first
        let matches = (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        )) ?? []
        return matches
            .filter { samePlaylist($0.id, as: prefix) && $0.id != movie.id }
            .map { .movie($0) }
    }

    /// Other `Series` entries that share `series`'s TMDB id and playlist,
    /// excluding `series` itself. Empty when the series has no TMDB id.
    static func resolve(for series: Series, in context: ModelContext) -> [HomeMediaItem] {
        guard let tmdbId = series.tmdbId else { return [] }
        let prefix = series.id.components(separatedBy: "-series-").first
        let matches = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        )) ?? []
        return matches
            .filter { samePlaylist($0.id, as: prefix) && $0.id != series.id }
            .map { .series($0) }
    }

    /// Whether `id` belongs to the same playlist as `prefix` (the `<uuid>` part of
    /// a content id). A nil prefix means the owner couldn't be determined — in
    /// that case keep the match rather than hiding everything.
    private static func samePlaylist(_ id: String, as prefix: String?) -> Bool {
        guard let prefix else { return true }
        return id.hasPrefix(prefix)
    }
}
