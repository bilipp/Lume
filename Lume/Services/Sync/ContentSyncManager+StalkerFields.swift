//
//  ContentSyncManager+StalkerFields.swift
//  Lume
//
//  Copies a Stalker portal's catalog fields onto the stored rows, writing only
//  what changed — the same rule as the Xtream, m3u, Jellyfin and Plex
//  importers. Assigning every field marked every row changed, so an unchanged
//  sync still rewrote the whole catalog (all 57k channels on a large portal) and
//  each save re-ran every live-TV query.
//

import Foundation

extension ContentSyncManager {
    func applyStalkerMovieFields(from item: StalkerVODItem, cmd: String, to movie: Movie, categoryId: String) {
        let name = item.name ?? ""
        if movie.name != name { movie.name = name }
        if movie.streamIcon != item.screenshot { movie.streamIcon = item.screenshot }
        if movie.plot != item.description { movie.plot = item.description }
        if movie.releaseDate != item.year { movie.releaseDate = item.year }
        if let rating = Double(item.rating ?? ""), movie.rating != rating { movie.rating = rating }
        if let added = item.added, movie.added != added { movie.added = added }
        if movie.categoryId != categoryId { movie.categoryId = categoryId }
        if movie.directURL != cmd { movie.directURL = cmd }
    }

    func applyStalkerSeriesFields(from item: StalkerVODItem, to series: Series, categoryId: String) {
        let name = item.name ?? ""
        if series.name != name { series.name = name }
        if series.cover != item.screenshot { series.cover = item.screenshot }
        if series.plot != item.description { series.plot = item.description }
        if series.releaseDate != item.year { series.releaseDate = item.year }
        // The Recently Added series rail orders by `lastModified`; the portal's
        // `added` timestamp is the closest equivalent.
        if let added = item.added, series.lastModified != added { series.lastModified = added }
        if series.categoryId != categoryId { series.categoryId = categoryId }
    }

    func applyStalkerChannelFields(from channel: StalkerChannel, cmd: String, to stream: LiveStream, playlistPrefix: String) {
        let name = channel.name ?? ""
        if stream.name != name { stream.name = name }
        if stream.streamIcon != channel.logo { stream.streamIcon = channel.logo }
        if stream.epgChannelId != channel.xmltvId { stream.epgChannelId = channel.xmltvId }
        if stream.directURL != cmd { stream.directURL = cmd }
        let number = channel.number ?? 0
        if stream.num != number { stream.num = number }
        if let genreId = channel.genreId {
            let categoryId = playlistPrefix + genreId
            if stream.categoryId != categoryId { stream.categoryId = categoryId }
        }
    }
}
