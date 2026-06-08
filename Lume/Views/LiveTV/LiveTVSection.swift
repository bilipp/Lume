//
//  LiveTVSection.swift
//  Lume
//
//  The Live TV browse surfaces (the category rail / sidebar / bar and the
//  channel list / EPG guide) are driven by "sections" rather than raw
//  categories: alongside each synced live `Category` there are two virtual
//  collections — Favorites and Recently Watched — that cut across categories.
//
//  A `LiveTVSection` is what the user selects in the rail; a `LiveChannelScope`
//  is what the channel list / guide query against. `LiveChannelQuery` builds the
//  right `@Query` descriptor (and the in-memory playlist scoping the virtual
//  collections need, since their predicate can't be parameterised on the
//  playlist-prefixed id).
//

import SwiftData
import SwiftUI

// MARK: - Section

/// A selectable entry in the Live TV category rail. Either a real synced
/// category or one of the virtual cross-category collections.
enum LiveTVSection: Identifiable, Hashable {
    case favorites
    case recentlyWatched
    case category(Category)

    var id: String {
        switch self {
        case .favorites: "lume.liveSection.favorites"
        case .recentlyWatched: "lume.liveSection.recentlyWatched"
        case let .category(category): category.id
        }
    }

    var scope: LiveChannelScope {
        switch self {
        case .favorites: .favorites
        case .recentlyWatched: .recentlyWatched
        case let .category(category): .category(category.id)
        }
    }

    /// SF Symbol shown beside the virtual collections; nil for plain categories.
    var icon: String? {
        switch self {
        case .favorites: "heart.fill"
        case .recentlyWatched: "clock.arrow.circlepath"
        case .category: nil
        }
    }

    /// Display label. Virtual collections are localized; category names are the
    /// provider's verbatim strings.
    var titleText: Text {
        switch self {
        case .favorites: Text("Favorites")
        case .recentlyWatched: Text("Recently Watched")
        case let .category(category): Text(category.name)
        }
    }

    /// Plain title used where a `String` is needed (e.g. tvOS minimumScaleFactor
    /// rows that style the label themselves).
    var title: String {
        switch self {
        case .favorites: String(localized: "Favorites")
        case .recentlyWatched: String(localized: "Recently Watched")
        case let .category(category): category.name
        }
    }

    var isVirtual: Bool {
        switch self {
        case .favorites, .recentlyWatched: true
        case .category: false
        }
    }
}

// MARK: - Scope

/// What a Live TV channel list / guide should show.
enum LiveChannelScope: Hashable {
    /// Channels in a single synced category (carries the category id).
    case category(String)
    /// Every favorited channel in the active playlist.
    case favorites
    /// Recently watched channels in the active playlist, newest first.
    case recentlyWatched
}

// MARK: - Query

enum LiveChannelQuery {
    /// Cap on the Recently Watched collection — watch history is naturally
    /// bounded but we don't want it to grow without limit.
    static let recentLimit = 50

    /// Builds the `@Query` descriptor for a scope. The category scope sorts by
    /// the user's content-sort choice; the virtual collections have an intrinsic
    /// order (favorites by their own custom order, recents by most-recent-first).
    static func descriptor(for scope: LiveChannelScope, sort: ContentSortOption) -> FetchDescriptor<LiveStream> {
        switch scope {
        case let .category(categoryId):
            return FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.categoryId == categoryId && $0.isHidden == false },
                sortBy: sort.liveStreamDescriptors
            )
        case .favorites:
            // `favoriteOrder` (nil-first) leads, exactly like `customOrder` for
            // categories: an un-reordered favorites list ties on nil and falls
            // through to the provider order, a reordered one sorts by the user's
            // arrangement. See ContentOrganizer.
            return FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.isFavorite && $0.isHidden == false },
                sortBy: [
                    SortDescriptor(\LiveStream.favoriteOrder),
                    SortDescriptor(\LiveStream.num),
                    SortDescriptor(\LiveStream.name)
                ]
            )
        case .recentlyWatched:
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.lastWatchedDate != nil && $0.isHidden == false },
                sortBy: [SortDescriptor(\LiveStream.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = recentLimit
            return descriptor
        }
    }

    /// Scopes a query's results to the active playlist. Category queries are
    /// already isolated (category ids are playlist-prefixed), but the virtual
    /// collections span every playlist, so they're filtered in-memory by the
    /// shared id prefix — the same approach used throughout the app.
    static func scoped(_ streams: [LiveStream], scope: LiveChannelScope, playlistPrefix: String) -> [LiveStream] {
        switch scope {
        case .category:
            streams
        case .favorites, .recentlyWatched:
            streams.filter { $0.id.hasPrefix(playlistPrefix) }
        }
    }
}
