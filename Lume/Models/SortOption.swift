//
//  SortOption.swift
//  Lume
//
//  Sort options for categories and the content inside them.
//  Playlist order is preserved via Category.sortOrder (set during sync) and
//  the stream-level `num` field that the Xtream API provides.
//

import Foundation
import SwiftData

// MARK: - Category Sort

enum CategorySortOption: String, CaseIterable, Identifiable {
    case playlist
    case nameAscending
    case nameDescending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playlist: return "Playlist Order"
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        }
    }

    var icon: String {
        switch self {
        case .playlist: return "list.number"
        case .nameAscending: return "textformat.abc"
        case .nameDescending: return "textformat.abc.dottedunderline"
        }
    }

    /// Sorts categories in memory. Used for category lists, which are small
    /// enough that an in-memory sort is simpler than a separate FetchDescriptor.
    func sort(_ categories: [Category]) -> [Category] {
        switch self {
        case .playlist:
            return categories.sorted(by: { (lhs: Category, rhs: Category) -> Bool in
                (lhs.sortOrder, lhs.name) < (rhs.sortOrder, rhs.name)
            })
        case .nameAscending:
            return categories.sorted(by: { (lhs: Category, rhs: Category) -> Bool in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            })
        case .nameDescending:
            return categories.sorted(by: { (lhs: Category, rhs: Category) -> Bool in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            })
        }
    }
}

// MARK: - Content Sort

enum ContentSortOption: String, CaseIterable, Identifiable {
    case playlist
    case nameAscending
    case nameDescending
    case newest
    case oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playlist: return "Playlist Order"
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        }
    }

    var icon: String {
        switch self {
        case .playlist: return "list.number"
        case .nameAscending: return "textformat.abc"
        case .nameDescending: return "textformat.abc.dottedunderline"
        case .newest: return "arrow.down.circle"
        case .oldest: return "arrow.up.circle"
        }
    }

    // MARK: SortDescriptor builders
    //
    // Each model has its own "added" field (Movie/LiveStream: `added`;
    // Series: `lastModified`). The Xtream API ships these as Unix timestamp
    // strings, so a lexicographic sort matches numeric order for the 10-digit
    // range this app will encounter.

    var movieDescriptors: [SortDescriptor<Movie>] {
        switch self {
        case .playlist:
            return [SortDescriptor(\Movie.num), SortDescriptor(\Movie.name)]
        case .nameAscending:
            return [SortDescriptor(\Movie.name, order: .forward)]
        case .nameDescending:
            return [SortDescriptor(\Movie.name, order: .reverse)]
        case .newest:
            return [SortDescriptor(\Movie.added, order: .reverse), SortDescriptor(\Movie.num)]
        case .oldest:
            return [SortDescriptor(\Movie.added, order: .forward), SortDescriptor(\Movie.num)]
        }
    }

    var seriesDescriptors: [SortDescriptor<Series>] {
        switch self {
        case .playlist:
            return [SortDescriptor(\Series.num), SortDescriptor(\Series.name)]
        case .nameAscending:
            return [SortDescriptor(\Series.name, order: .forward)]
        case .nameDescending:
            return [SortDescriptor(\Series.name, order: .reverse)]
        case .newest:
            return [SortDescriptor(\Series.lastModified, order: .reverse), SortDescriptor(\Series.num)]
        case .oldest:
            return [SortDescriptor(\Series.lastModified, order: .forward), SortDescriptor(\Series.num)]
        }
    }

    var liveStreamDescriptors: [SortDescriptor<LiveStream>] {
        switch self {
        case .playlist:
            return [SortDescriptor(\LiveStream.num), SortDescriptor(\LiveStream.name)]
        case .nameAscending:
            return [SortDescriptor(\LiveStream.name, order: .forward)]
        case .nameDescending:
            return [SortDescriptor(\LiveStream.name, order: .reverse)]
        case .newest:
            return [SortDescriptor(\LiveStream.added, order: .reverse), SortDescriptor(\LiveStream.num)]
        case .oldest:
            return [SortDescriptor(\LiveStream.added, order: .forward), SortDescriptor(\LiveStream.num)]
        }
    }
}

// MARK: - AppStorage keys

enum SortStorageKey {
    static let liveCategories = "lume.sort.live.categories"
    static let liveContent = "lume.sort.live.content"
    static let movieCategories = "lume.sort.movies.categories"
    static let movieContent = "lume.sort.movies.content"
    static let seriesCategories = "lume.sort.series.categories"
    static let seriesContent = "lume.sort.series.content"
}
