//
//  WidgetProviders.swift
//  LumeWidgets
//
//  Timeline providers for the three widgets. Data comes from the shared
//  snapshot; artwork is fetched (downsampled) inside the provider — never in
//  the views, which are rendered and archived by the system.
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import WidgetKit

// MARK: - Entries

struct MediaEntry: TimelineEntry {
    let date: Date
    let items: [WidgetMediaItem]
    let images: [URL: Image]
}

struct OnNowEntry: TimelineEntry {
    let date: Date
    let channels: [WidgetChannelNow]
    let images: [URL: Image]
}

// MARK: - Providers

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in _: Context) -> MediaEntry {
        MediaEntry(date: Date(), items: WidgetSampleData.continueWatching, images: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (MediaEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { await completion(Self.entry()) }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<MediaEntry>) -> Void) {
        Task {
            // The app reloads timelines whenever it writes a fresh snapshot, so
            // there is nothing to poll for — `.never` preserves reload budget.
            await completion(Timeline(entries: [Self.entry()], policy: .never))
        }
    }

    private static func entry() async -> MediaEntry {
        let items = WidgetDataStore.load()?.continueWatching ?? []
        let images = await WidgetImageLoader.load(urls: items.prefix(6).compactMap(\.imageURL))
        return MediaEntry(date: Date(), items: items, images: images)
    }
}

struct FavoritesProvider: TimelineProvider {
    func placeholder(in _: Context) -> MediaEntry {
        MediaEntry(date: Date(), items: WidgetSampleData.favorites, images: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (MediaEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { await completion(Self.entry()) }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<MediaEntry>) -> Void) {
        Task {
            await completion(Timeline(entries: [Self.entry()], policy: .never))
        }
    }

    private static func entry() async -> MediaEntry {
        let items = WidgetDataStore.load()?.favorites ?? []
        let images = await WidgetImageLoader.load(urls: items.prefix(8).compactMap(\.imageURL))
        return MediaEntry(date: Date(), items: items, images: images)
    }
}

struct OnNowProvider: TimelineProvider {
    func placeholder(in _: Context) -> OnNowEntry {
        OnNowEntry(date: Date(), channels: WidgetSampleData.onNow, images: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (OnNowEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { await completion(Self.entry(now: Date())) }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<OnNowEntry>) -> Void) {
        Task {
            let now = Date()
            let entry = await Self.entry(now: now)
            // Refresh when the earliest programme ends so "on now" rolls over,
            // clamped to [5 min, 60 min] to stay inside the reload budget.
            // Progress bars advance live via ProgressView(timerInterval:).
            let boundaries = entry.channels
                .flatMap { [$0.nowEnd, $0.nextStart] }
                .compactMap(\.self)
                .filter { $0 > now }
            let refresh = min(
                max(boundaries.min() ?? now.addingTimeInterval(3600), now.addingTimeInterval(300)),
                now.addingTimeInterval(3600)
            )
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    private static func entry(now: Date) async -> OnNowEntry {
        let channels = WidgetDataStore.load()?.onNow ?? []
        let images = await WidgetImageLoader.load(urls: channels.prefix(8).compactMap(\.logoURL), maxPixel: 160)
        return OnNowEntry(date: now, channels: channels, images: images)
    }
}

// MARK: - Artwork

/// Fetches artwork for timeline entries. Widget extensions run in a ~30 MB
/// memory budget, so every image is decoded through an ImageIO thumbnail —
/// never a full-size decode of a provider poster.
enum WidgetImageLoader {
    static func load(urls: some Collection<URL>, maxPixel: Int = 480) async -> [URL: Image] {
        await withTaskGroup(of: (URL, Image?).self) { group in
            for url in Set(urls) {
                group.addTask { await (url, fetch(url: url, maxPixel: maxPixel)) }
            }
            var result: [URL: Image] = [:]
            for await (url, image) in group {
                if let image { result[url] = image }
            }
            return result
        }
    }

    private static func fetch(url: URL, maxPixel: Int) async -> Image? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return downsampled(data: data, maxPixel: maxPixel)
    }

    private static func downsampled(data: Data, maxPixel: Int) -> Image? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

// MARK: - Gallery samples

/// Fabricated content for the widget gallery (`placeholder` / preview
/// snapshots). Deep links are never followed there, so a bare scheme URL is fine.
enum WidgetSampleData {
    private static let sampleLink = URL(string: "lume://open/series/sample") ?? URL(fileURLWithPath: "/")

    static let continueWatching: [WidgetMediaItem] = [
        WidgetMediaItem(id: "1", kind: .movie, title: "The Long Voyage", subtitle: "2024", imageURL: nil, progress: 0.4, deepLink: sampleLink),
        WidgetMediaItem(id: "2", kind: .episode, title: "Northern Lights", subtitle: "S1 E4 · Aurora", imageURL: nil, progress: 0.7, deepLink: sampleLink),
        WidgetMediaItem(id: "3", kind: .movie, title: "Riverbend", subtitle: "2023", imageURL: nil, progress: 0.2, deepLink: sampleLink)
    ]

    static let favorites: [WidgetMediaItem] = [
        WidgetMediaItem(id: "1", kind: .live, title: "News 24", subtitle: nil, imageURL: nil, progress: nil, deepLink: sampleLink),
        WidgetMediaItem(id: "2", kind: .movie, title: "The Long Voyage", subtitle: nil, imageURL: nil, progress: nil, deepLink: sampleLink),
        WidgetMediaItem(id: "3", kind: .series, title: "Northern Lights", subtitle: nil, imageURL: nil, progress: nil, deepLink: sampleLink),
        WidgetMediaItem(id: "4", kind: .live, title: "Sports One", subtitle: nil, imageURL: nil, progress: nil, deepLink: sampleLink)
    ]

    static let onNow: [WidgetChannelNow] = [
        WidgetChannelNow(
            id: "1", channelName: "News 24", logoURL: nil,
            nowTitle: "Evening News", nowStart: Date().addingTimeInterval(-900), nowEnd: Date().addingTimeInterval(1800),
            nextTitle: "Weather", nextStart: Date().addingTimeInterval(1800), deepLink: sampleLink
        ),
        WidgetChannelNow(
            id: "2", channelName: "Sports One", logoURL: nil,
            nowTitle: "Match Day Live", nowStart: Date().addingTimeInterval(-2700), nowEnd: Date().addingTimeInterval(2700),
            nextTitle: "Highlights", nextStart: Date().addingTimeInterval(2700), deepLink: sampleLink
        )
    ]
}
