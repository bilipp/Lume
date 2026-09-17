//
//  ContentOrganizing.swift
//  Lume
//
//  Shared reorder / hide / reset logic for the Content Management feature.
//  Categories and live channels both carry a `customOrder` and an `isHidden`
//  flag, so the organizing operations are written once against a protocol and
//  reused for both.
//
//  Ordering convention: `customOrder` is `nil` until the user reorders a group,
//  at which point every member of that group is stamped with a dense index
//  (0, 1, 2, …). Keeping the assignment dense and all-or-nothing means a plain
//  `SortDescriptor(\.customOrder)` (nil-first) behaves correctly — an untouched
//  group all ties on nil and falls through to the provider order, while a
//  reordered group sorts purely by the user's choice. "Reset" clears the group
//  back to `nil`.
//

import Foundation
import SwiftUI // for Array.move(fromOffsets:toOffset:)

/// The minimal identity a row needs to appear in a reorderable Content
/// Management list (`TVReorderableContentList`). `ContentItem` refines it for the
/// category/channel lists; the unified favorites manager's row wrapper — which is
/// a value type spanning three model types — conforms directly.
protocol ReorderableRowItem {
    var id: String { get }
}

/// A piece of content the user can hide and reorder in Content Management.
protocol ContentItem: ReorderableRowItem, AnyObject {
    var customOrder: Int? { get set }
    var isHidden: Bool { get set }
}

extension Category: ContentItem {}
extension LiveStream: ContentItem {}

enum ContentOrganizer {
    /// Applies a SwiftUI `.onMove` to an already-sorted group and stamps a dense
    /// `customOrder` so the new arrangement persists.
    static func reorder(_ items: [some ContentItem], from source: IndexSet, to destination: Int) {
        var arranged = items
        arranged.move(fromOffsets: source, toOffset: destination)
        stampOrder(arranged)
    }

    /// Persists an explicit final arrangement in one pass, stamping a dense
    /// `customOrder`. Used by the tvOS pick-up/place reorder, which arranges a
    /// *local* working copy as the user slides a lifted row and commits only
    /// once on drop — never touching SwiftData during the move itself.
    static func commitOrder(_ arranged: [some ContentItem]) {
        stampOrder(arranged)
    }

    /// Clears the user-defined order for a group, reverting to provider order.
    static func resetOrder(_ items: [some ContentItem]) {
        for item in items {
            item.customOrder = nil
        }
    }

    /// Un-hides every item in a group.
    static func showAll(_ items: [some ContentItem]) {
        for item in items {
            item.isHidden = false
        }
    }

    /// Hides every item in a group — the counterpart to `showAll`, so a user with
    /// a 10k-channel provider can start from a blank slate and opt content back
    /// in rather than tapping thousands of per-row toggles.
    static func hideAll(_ items: [some ContentItem]) {
        for item in items {
            item.isHidden = true
        }
    }

    private static func stampOrder(_ arranged: [some ContentItem]) {
        stamp(arranged, into: \.customOrder)
    }

    private static func stamp<Item: AnyObject>(_ arranged: [Item], into keyPath: ReferenceWritableKeyPath<Item, Int?>) {
        for (index, item) in arranged.enumerated() {
            item[keyPath: keyPath] = index
        }
    }
}

// MARK: - Favorites ordering

/// Content that carries an independent ordering for the unified Favorites
/// collection, alongside any primary `customOrder`. Movies, series and live
/// channels all conform, so the favorites manager can arrange the three types in
/// a single list and a movie can sit above a channel. `favoriteOrder` is stamped
/// densely across *all* favorites regardless of type, so a plain sort by it
/// interleaves the types in the user's chosen order. It's kept separate from a
/// channel's within-category `customOrder`, which is an independent placement.
protocol FavoriteOrderable: AnyObject {
    var id: String { get }
    var favoriteOrder: Int? { get set }
    var isFavorite: Bool { get set }
}

extension LiveStream: FavoriteOrderable {}
extension Movie: FavoriteOrderable {}
extension Series: FavoriteOrderable {}

/// Favoritable content that also carries a watchlist stamp: movies and series.
/// A `LiveStream` has no `addedToWatchlistDate`, which is the whole reason the
/// VOD favorite semantic (`MediaFavorites`) is separate from the live one.
protocol WatchlistFavoritable: FavoriteOrderable {
    var addedToWatchlistDate: Date? { get set }
}

extension Movie: WatchlistFavoritable {}
extension Series: WatchlistFavoritable {}

extension ContentOrganizer {
    /// Applies a SwiftUI `.onMove` to an already-sorted favorites list and stamps
    /// a dense `favoriteOrder` so the arrangement persists. The list is
    /// heterogeneous (movies, series, channels), so a single dense stamp across
    /// the whole array is what lets the types interleave.
    static func reorderFavorites(_ items: [any FavoriteOrderable], from source: IndexSet, to destination: Int) {
        var arranged = items
        arranged.move(fromOffsets: source, toOffset: destination)
        stampFavoriteOrder(arranged)
    }

    /// Persists an explicit final favorites arrangement in one pass (tvOS
    /// pick-up/place reorder).
    static func commitFavoriteOrder(_ arranged: [any FavoriteOrderable]) {
        stampFavoriteOrder(arranged)
    }

    /// Clears the user-defined favorites order, reverting to the default order.
    static func resetFavoriteOrder(_ items: [any FavoriteOrderable]) {
        for item in items {
            item.favoriteOrder = nil
        }
    }

    private static func stampFavoriteOrder(_ arranged: [any FavoriteOrderable]) {
        for (index, item) in arranged.enumerated() {
            item.favoriteOrder = index
        }
    }
}
