//
//  SearchModels.swift
//  Lume
//
//  Settings, filter and result types for global search
//

import SwiftData
import SwiftUI

// MARK: - Search Settings

enum SearchSettings {
    /// When enabled, search spans every configured playlist. Off by default, so
    /// results stay scoped to the active playlist unless the user opts in.
    static let searchAllPlaylistsKey = "search.allPlaylists"
    static let searchAllPlaylistsDefault = false
}

// MARK: - Content Filter

enum ContentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case series = "Series"
    case liveTV = "Live TV"

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// MARK: - Search Result

enum SearchResult: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)
    case liveStream(LiveStream)

    var id: String {
        switch self {
        case let .movie(movie):
            "movie-\(movie.id)"
        case let .series(series):
            "series-\(series.id)"
        case let .liveStream(stream):
            "live-\(stream.id)"
        }
    }

    var tab: PlaylistTab {
        switch self {
        case .movie: .movies
        case .series: .series
        case .liveStream: .liveTV
        }
    }

    /// The catalog row's own id, which carries the owning playlist's UUID as a
    /// prefix. `id` above namespaces by kind so a movie and a channel can't
    /// collide in the list; this one is what `owner(ofContentID:)` reads.
    var contentID: String {
        switch self {
        case let .movie(movie): movie.id
        case let .series(series): series.id
        case let .liveStream(stream): stream.id
        }
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#Preview("Empty") {
    SearchView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    SearchView()
        .modelContainer(previewContainer())
}
