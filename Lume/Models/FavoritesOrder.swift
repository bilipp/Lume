//
//  FavoritesOrder.swift
//  Lume
//
//  The cross-type order of favorites — movies, series and channels — shared by
//  Home's Favorites rail and Content Management → Favorites.
//

import Foundation

nonisolated enum FavoritesOrder {
    /// One favorite's sort inputs. `kind` is the type fallback: channels (0),
    /// movies (1), then series (2).
    nonisolated struct Entry<Item> {
        let order: Int?
        let member: Int
        let kind: Int
        let num: Int
        let name: String
        let item: Item
    }

    /// The cross-type `favoriteOrder` first, so a movie placed above a channel
    /// stays above it. Items never reordered (nil) go last, by member priority
    /// (constant outside Combined), then type, provider number and name.
    static func sorted<Item>(_ entries: [Entry<Item>]) -> [Item] {
        entries
            .sorted {
                ($0.order ?? .max, $0.member, $0.kind, $0.num, $0.name)
                    < ($1.order ?? .max, $1.member, $1.kind, $1.num, $1.name)
            }
            .map(\.item)
    }
}
