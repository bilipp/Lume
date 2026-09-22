//
//  WidgetSnapshot.swift
//  LumeShared
//
//  The value-type snapshot the app exports for its widgets. Compiled into the
//  app, the WidgetKit extension and the tvOS Top Shelf extension, so it must
//  stay a plain Codable surface with no SwiftData / app dependencies.
//  Everything is `nonisolated`: the app target builds with default MainActor
//  isolation while the extensions don't, and these values cross actors freely.
//

import Foundation

/// Everything the widgets and the Top Shelf can render, precomputed by the app
/// (see `WidgetSnapshotExporter`) and written to the shared App Group container.
/// Extensions never query the catalog — they read this file only.
nonisolated struct WidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    var continueWatching: [WidgetMediaItem]
    var favorites: [WidgetMediaItem]
    var onNow: [WidgetChannelNow]

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        continueWatching: [],
        favorites: [],
        onNow: []
    )
}

/// One resumable or favorite title. `deepLink` carries the full launch intent so
/// renderers never rebuild routing logic.
nonisolated struct WidgetMediaItem: Codable, Equatable, Identifiable {
    nonisolated enum Kind: String, Codable {
        case movie
        case episode
        case series
        case live
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var imageURL: URL?
    /// Resume fraction (0...1) for partially-watched items, nil otherwise.
    var progress: Double?
    var deepLink: URL
}

/// The now/next programme pair for one favorite channel, resolved from the EPG
/// at export time. Widgets re-render at programme boundaries from these dates.
nonisolated struct WidgetChannelNow: Codable, Equatable, Identifiable {
    var id: String
    var channelName: String
    var logoURL: URL?
    var nowTitle: String?
    var nowStart: Date?
    var nowEnd: Date?
    var nextTitle: String?
    var nextStart: Date?
    var deepLink: URL
}
