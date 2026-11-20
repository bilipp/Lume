//
//  TitleGroupFavorites.swift
//  Lume
//
//  The favorite toggle behind a grouped card's menu. The card reads as a
//  favorite when any copy of its title is one, so turning that off clears every
//  copy; turning it on writes only the row the card shows.
//

import Foundation
import SwiftData

/// A movie or series row a grouped card can favorite.
typealias TitleGroupFavoritable = TitleGroupStateRow & TitleSiblingRow & WatchlistFavoritable & WatchlistRow

enum TitleGroupFavorites {
    /// - Parameter showsFavorite: what the card currently shows, i.e. the
    ///   aggregated state, not the row's own flag.
    static func toggle(_ row: some TitleGroupFavoritable, showsFavorite: Bool, in context: ModelContext) {
        if showsFavorite {
            TitleGroupSiblings.unfavorite(row, in: context)
            try? context.save()
        } else {
            MediaFavorites.toggle(row, in: context)
        }
    }

    /// Toggles against the state `states` holds for `row`'s title, then
    /// re-reads that title's entry.
    static func toggle<Row: TitleGroupFavoritable>(
        _ row: Row,
        updating states: inout [String: TitleGroupState],
        in context: ModelContext
    ) {
        toggle(row, showsFavorite: TitleGroupStateLookup.state(of: row, in: states).isFavorite, in: context)
        guard let key = row.titleGroupKey else { return }
        states.replace(keys: [key], with: Row.groupStates(keys: [key], in: context))
    }
}
