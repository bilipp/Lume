//
//  ContentProvider.swift
//  LumeTopShelf
//
//  The tvOS Top Shelf — the marquee row above the app icon on the Apple TV
//  home screen. Mirrors the widgets: Continue Watching, Favorites and On Now
//  sections from the shared snapshot the app exports. Selecting an item
//  deep-links into the app via `lume://`; the system fetches artwork itself
//  from the URLs we hand it.
//

import Foundation
import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = WidgetDataStore.load() else {
            completionHandler(nil)
            return
        }

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        let continueWatching = snapshot.continueWatching.prefix(10).compactMap(mediaItem)
        if !continueWatching.isEmpty {
            let section = TVTopShelfItemCollection(items: continueWatching)
            section.title = String(localized: "Continue Watching", comment: "Top Shelf section")
            sections.append(section)
        }

        let onNow = snapshot.onNow.prefix(10).compactMap(channelItem)
        if !onNow.isEmpty {
            let section = TVTopShelfItemCollection(items: onNow)
            section.title = String(localized: "On Now", comment: "Top Shelf section")
            sections.append(section)
        }

        let favorites = snapshot.favorites.prefix(10).compactMap(mediaItem)
        if !favorites.isEmpty {
            let section = TVTopShelfItemCollection(items: favorites)
            section.title = String(localized: "Favorites", comment: "Top Shelf section")
            sections.append(section)
        }

        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private func mediaItem(_ media: WidgetMediaItem) -> TVTopShelfSectionedItem? {
        let item = TVTopShelfSectionedItem(identifier: media.id)
        item.title = media.title
        item.imageShape = media.kind == .live ? .square : .poster
        if let imageURL = media.imageURL {
            item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
        }
        if let progress = media.progress {
            item.playbackProgress = progress
        }
        item.displayAction = TVTopShelfAction(url: media.deepLink)
        item.playAction = TVTopShelfAction(url: media.deepLink)
        return item
    }

    private func channelItem(_ channel: WidgetChannelNow) -> TVTopShelfSectionedItem? {
        let item = TVTopShelfSectionedItem(identifier: channel.id)
        if let nowTitle = channel.nowTitle {
            item.title = "\(channel.channelName) — \(nowTitle)"
        } else {
            item.title = channel.channelName
        }
        item.imageShape = .square
        if let logoURL = channel.logoURL {
            item.setImageURL(logoURL, for: [.screenScale1x, .screenScale2x])
        }
        item.displayAction = TVTopShelfAction(url: channel.deepLink)
        item.playAction = TVTopShelfAction(url: channel.deepLink)
        return item
    }
}
