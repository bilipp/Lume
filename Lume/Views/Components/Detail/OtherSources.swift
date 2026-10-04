//
//  OtherSources.swift
//  Lume
//
//  Resolves other entries of the *same* title (matched by TMDB id) for the
//  "Other Sources" row: alternate streams within the same playlist (e.g. a
//  different quality or language) followed by copies on the user's other
//  playlists, the latter labelled with the owning playlist's name so the UI can
//  badge them. Shared by the movie and series detail screens (iOS, macOS and
//  tvOS) so the row behaves identically everywhere.
//

import Foundation
import SwiftData

enum OtherSources {
    /// One entry of the same title: an alternate stream in the same playlist
    /// (no label) or a copy on another playlist (labelled with that playlist's
    /// name).
    struct Source: Identifiable, Hashable {
        let item: HomeMediaItem
        let playlistName: String?

        var id: String {
            item.id
        }
    }

    /// Other `Movie` entries that share `movie`'s TMDB id, excluding `movie`
    /// itself. Empty when the movie has no TMDB id.
    static func resolve(for movie: Movie, in context: ModelContext) -> [Source] {
        guard let tmdbId = movie.tmdbId else { return [] }
        let prefix = movie.id.components(separatedBy: "-movie-").first
        let matches = (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        )) ?? []
        return sources(
            matches.filter { $0.id != movie.id }.map { ($0.id, HomeMediaItem.movie($0)) },
            ownPlaylist: prefix,
            in: context
        )
    }

    /// Other `Series` entries that share `series`'s TMDB id, excluding `series`
    /// itself. Empty when the series has no TMDB id.
    static func resolve(for series: Series, in context: ModelContext) -> [Source] {
        guard let tmdbId = series.tmdbId else { return [] }
        let prefix = series.id.components(separatedBy: "-series-").first
        let matches = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        )) ?? []
        return sources(
            matches.filter { $0.id != series.id }.map { ($0.id, HomeMediaItem.series($0)) },
            ownPlaylist: prefix,
            in: context
        )
    }

    /// Same-playlist entries first (unlabelled), then entries from other
    /// playlists labelled with the owning playlist's name and sorted by it.
    /// Cross-playlist entries whose playlist can't be resolved are dropped —
    /// without a playlist there are no credentials to play them with. A nil
    /// prefix means the owner couldn't be determined; keep everything
    /// unlabelled rather than guessing.
    private static func sources(
        _ candidates: [(id: String, item: HomeMediaItem)],
        ownPlaylist prefix: String?,
        in context: ModelContext
    ) -> [Source] {
        guard let prefix else {
            return candidates.map { Source(item: $0.item, playlistName: nil) }
        }
        let own = candidates
            .filter { $0.id.hasPrefix(prefix) }
            .map { Source(item: $0.item, playlistName: nil) }
        let foreign = candidates.filter { !$0.id.hasPrefix(prefix) }
        guard !foreign.isEmpty else { return own }
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        let labelled = foreign
            .compactMap { candidate in
                playlists.first { candidate.id.hasPrefix($0.id.uuidString) }
                    .map { Source(item: candidate.item, playlistName: $0.name) }
            }
            .sorted { ($0.playlistName ?? "").localizedStandardCompare($1.playlistName ?? "") == .orderedAscending }
        return own + labelled
    }
}
