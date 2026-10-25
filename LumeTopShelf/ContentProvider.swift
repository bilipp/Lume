//
//  ContentProvider.swift
//  LumeTopShelf
//
//  The tvOS Top Shelf — the marquee row above the app icon on the Apple TV
//  home screen: Continue Watching and Favorites
//  from the shared snapshot the app exports, shown, ordered and sized the way
//  the user set it up in Settings › Home (`TopShelfConfiguration`). Selecting
//  an item deep-links into the app via `lume://`. The system fetches poster
//  and backdrop artwork itself; channel logos go up as tiles rendered here
//  (`ChannelTileRenderer`).
//

import Foundation
import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = WidgetDataStore.load() else {
            completionHandler(nil)
            return
        }
        let configuration = snapshot.topShelf ?? .default
        let sections = configuration.isEnabled
            ? TopShelfSection.build(from: snapshot, configuration: configuration)
            : []
        // Switched off, or nothing to show: tvOS falls back to the app's static
        // Top Shelf image.
        guard !sections.isEmpty else {
            completionHandler(nil)
            return
        }
        switch configuration.style {
        case .sectioned:
            // Channel logos go up as rendered tiles (see `ChannelTileRenderer`),
            // which takes a download per new logo — hence the async hop.
            let channels = sections.flatMap(\.entries).filter(\.isChannel).map {
                ChannelTileRenderer.Channel(id: $0.id, name: $0.title, logoURL: $0.posterURL)
            }
            Task {
                let tiles = await ChannelTileRenderer.tiles(for: channels)
                completionHandler(TVTopShelfSectionedContent(sections: sections.map { $0.sectionedCollection(tiles: tiles) }))
            }
        case .carousel:
            let items = TopShelfSection.carouselItems(sections)
            completionHandler(items.isEmpty ? nil : TVTopShelfCarouselContent(style: .details, items: items))
        }
    }
}

/// One configured section's entries, ready to become either layout's items.
private struct TopShelfSection {
    let kind: TopShelfConfiguration.Section
    let entries: [Entry]

    /// A single Top Shelf entry, from either a title or a channel.
    struct Entry {
        let id: String
        let title: String
        let summary: String?
        let posterURL: URL?
        let backdropURL: URL?
        let isChannel: Bool
        let progress: Double?
        /// Played by the remote's Play button.
        let deepLink: URL
        /// Opened on Select: the detail screen, so a click never starts
        /// playback by surprise. Nil for a channel, which has none.
        let detailLink: URL?

        /// Select opens the detail screen; Play plays. A channel plays on both.
        func applyActions(to item: TVTopShelfItem) {
            item.displayAction = TVTopShelfAction(url: detailLink ?? deepLink)
            item.playAction = TVTopShelfAction(url: deepLink)
        }
    }

    var title: String {
        switch kind {
        case .continueWatching: String(localized: "Continue Watching", comment: "Top Shelf section")
        case .favorites: String(localized: "Favorites", comment: "Top Shelf section")
        }
    }

    /// The configured sections in order, each capped at the chosen size;
    /// empty sections are left out.
    static func build(from snapshot: WidgetSnapshot, configuration: TopShelfConfiguration) -> [TopShelfSection] {
        configuration.sections.compactMap { kind in
            let entries: [Entry] = switch kind {
            case .continueWatching: snapshot.continueWatching.map(Entry.init(media:))
            case .favorites: snapshot.favorites.map(Entry.init(media:))
            }
            let capped = Array(entries.prefix(configuration.itemsPerSection))
            return capped.isEmpty ? nil : TopShelfSection(kind: kind, entries: capped)
        }
    }

    /// `tiles` holds the rendered channel tiles, keyed by entry id.
    func sectionedCollection(tiles: [String: URL]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        // Identifiers are scoped to the section: a favorite that's also in
        // progress appears in both rows.
        let collection = TVTopShelfItemCollection(items: entries.map {
            $0.sectionedItem(identifier: "\(kind.rawValue)-\($0.id)", tile: tiles[$0.id])
        })
        collection.title = title
        return collection
    }

    /// The carousel is one flat list: the sections in order, each item labelled
    /// with its section, and a title that appears in two sections (a favorite
    /// that's also in progress) shown once. Channels are left out — a logo is
    /// all the art they have, and it can't fill a full-screen backdrop — so On
    /// Now and favorite channels show only in the sectioned layout.
    static func carouselItems(_ sections: [TopShelfSection]) -> [TVTopShelfCarouselItem] {
        var seen = Set<String>()
        return sections.flatMap { section in
            section.entries
                .filter { !$0.isChannel && seen.insert($0.id).inserted }
                .map { $0.carouselItem(contextTitle: section.title) }
        }
    }
}

private extension TopShelfSection.Entry {
    init(media: WidgetMediaItem) {
        self.init(
            id: media.id,
            title: media.title,
            summary: media.subtitle,
            posterURL: media.imageURL,
            backdropURL: media.backdropURL,
            isChannel: media.kind == .live,
            progress: media.progress,
            deepLink: media.deepLink,
            detailLink: media.detailLink
        )
    }

    func sectionedItem(identifier: String, tile: URL?) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: identifier)
        item.title = title
        item.imageShape = isChannel ? .square : .poster
        if let imageURL = isChannel ? tile : posterURL {
            item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
        }
        if let progress {
            item.playbackProgress = progress
        }
        applyActions(to: item)
        return item
    }

    func carouselItem(contextTitle: String) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: id)
        item.title = title
        item.contextTitle = contextTitle
        item.summary = summary
        // Landscape art fills the carousel; a poster or logo is the fallback.
        if let imageURL = backdropURL ?? posterURL {
            item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
        }
        // Carousel items have no progress bar (`playbackProgress` is a
        // sectioned-item property), so resume state shows only in Rows.
        applyActions(to: item)
        return item
    }
}
