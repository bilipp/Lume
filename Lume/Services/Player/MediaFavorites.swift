//
//  MediaFavorites.swift
//  Lume
//
//  The one VOD favorite semantic, shared by the card menus, the detail screens,
//  the favorites manager and `PlayerFavorites`: a movie or series also stamps
//  `addedToWatchlistDate`, unlike a live stream which toggles the flag alone
//  (`LiveChannelFavorites`). An episode routes to its parent — episodes have no
//  `isFavorite` of their own.
//

import Foundation
import SwiftData

/// Flips the favorite state of a movie or series.
///
/// A new favorite deliberately leaves `favoriteOrder` alone. Both surfaces that
/// render favorites sort on `favoriteOrder ?? Int.max` (`HomeView.favoriteItems`
/// and `FavoriteManagementView`), so an unstamped favorite already sorts *after*
/// every hand-ordered one — stamping a next-highest slot here would instead put
/// it ahead of the whole unordered block for anyone who never opened the
/// favorites manager.
enum MediaFavorites {
    @discardableResult
    static func toggle(_ model: some WatchlistFavoritable, in context: ModelContext) -> Bool {
        let favorited = !model.isFavorite
        if favorited {
            model.isFavorite = true
            model.addedToWatchlistDate = Date()
        } else {
            clearFavoriteState(model)
        }
        try? context.save()
        return favorited
    }

    @discardableResult
    static func toggle(_ episode: Episode, in context: ModelContext) -> Bool {
        guard let series = episode.series else { return false }
        return toggle(series, in: context)
    }

    /// The single unfavorite semantic, shared with `FavoriteManagementView`.
    ///
    /// All three fields have to go: `ContentStateValues.isEmpty` requires
    /// `!isFavorite && addedToWatchlistDate == nil && favoriteOrder == nil`
    /// before `CloudSyncEngine` deletes the iCloud mirror record — leave the
    /// watchlist stamp behind and the record survives with `isFavorite == false`.
    /// Saving is the caller's business, since the favorites manager mutates
    /// under its own `@Query` context.
    static func clearFavoriteState(_ model: any FavoriteOrderable) {
        model.isFavorite = false
        model.favoriteOrder = nil
        (model as? any WatchlistFavoritable)?.addedToWatchlistDate = nil
    }
}
