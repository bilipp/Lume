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
import SwiftUI

// MARK: - Category Sort

enum CategorySortOption: String, CaseIterable, Identifiable {
    case playlist
    case nameAscending
    case nameDescending

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        switch self {
        case .playlist: "Playlist Order"
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        }
    }

    var icon: String {
        switch self {
        case .playlist: "list.number"
        case .nameAscending: "textformat.abc"
        case .nameDescending: "textformat.abc.dottedunderline"
        }
    }

    /// Sorts categories in memory. Used for category lists, which are small
    /// enough that an in-memory sort is simpler than a separate FetchDescriptor.
    func sort(_ categories: [Category]) -> [Category] {
        switch self {
        case .playlist:
            // A user-defined order (set in Content Management) takes precedence;
            // categories without one fall back to the synced playlist order.
            categories.sorted(by: { (lhs: Category, rhs: Category) -> Bool in
                (lhs.customOrder ?? lhs.sortOrder, lhs.name) < (rhs.customOrder ?? rhs.sortOrder, rhs.name)
            })
        case .nameAscending:
            categories.sorted(by: { (lhs: Category, rhs: Category) -> Bool in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            })
        case .nameDescending:
            categories.sorted(by: { (lhs: Category, rhs: Category) -> Bool in
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

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        switch self {
        case .playlist: "Playlist Order"
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        }
    }

    var icon: String {
        switch self {
        case .playlist: "list.number"
        case .nameAscending: "textformat.abc"
        case .nameDescending: "textformat.abc.dottedunderline"
        case .newest: "arrow.down.circle"
        case .oldest: "arrow.up.circle"
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
            [SortDescriptor(\Movie.num), SortDescriptor(\Movie.name)]
        case .nameAscending:
            [SortDescriptor(\Movie.name, order: .forward)]
        case .nameDescending:
            [SortDescriptor(\Movie.name, order: .reverse)]
        case .newest:
            [SortDescriptor(\Movie.added, order: .reverse), SortDescriptor(\Movie.num)]
        case .oldest:
            [SortDescriptor(\Movie.added, order: .forward), SortDescriptor(\Movie.num)]
        }
    }

    var seriesDescriptors: [SortDescriptor<Series>] {
        switch self {
        case .playlist:
            [SortDescriptor(\Series.num), SortDescriptor(\Series.name)]
        case .nameAscending:
            [SortDescriptor(\Series.name, order: .forward)]
        case .nameDescending:
            [SortDescriptor(\Series.name, order: .reverse)]
        case .newest:
            [SortDescriptor(\Series.lastModified, order: .reverse), SortDescriptor(\Series.num)]
        case .oldest:
            [SortDescriptor(\Series.lastModified, order: .forward), SortDescriptor(\Series.num)]
        }
    }

    var liveStreamDescriptors: [SortDescriptor<LiveStream>] {
        switch self {
        case .playlist:
            // `customOrder` (nil-first) leads: an un-reordered category ties on
            // nil and falls through to the provider order, while a reordered one
            // sorts by the user's arrangement. See ContentOrganizer.
            [SortDescriptor(\LiveStream.customOrder), SortDescriptor(\LiveStream.num), SortDescriptor(\LiveStream.name)]
        case .nameAscending:
            [SortDescriptor(\LiveStream.name, order: .forward)]
        case .nameDescending:
            [SortDescriptor(\LiveStream.name, order: .reverse)]
        case .newest:
            [SortDescriptor(\LiveStream.added, order: .reverse), SortDescriptor(\LiveStream.num)]
        case .oldest:
            [SortDescriptor(\LiveStream.added, order: .forward), SortDescriptor(\LiveStream.num)]
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
