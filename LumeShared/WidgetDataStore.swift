//
//  WidgetDataStore.swift
//  LumeShared
//
//  Reads/writes the widget snapshot in the shared App Group container, and
//  builds the `lume://` deep links widget taps launch the app with. Shared by
//  the app (writer) and both extensions (readers).
//

import Foundation

/// The snapshot file in the App Group container. The app is the only writer;
/// the WidgetKit and Top Shelf extensions only read.
nonisolated enum WidgetDataStore {
    /// Must match `com.apple.security.application-groups` in every target's
    /// entitlements (app, LumeWidgets, LumeTopShelf).
    static let appGroupID = "group.com.bilipp.lume"

    private static let snapshotFilename = "widget-snapshot.json"

    static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(snapshotFilename)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) throws {
        guard let url = snapshotURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}

/// Builds the widget-facing `lume://` URLs. The app-side parser lives in
/// `DeepLink` (app target); `DeepLinkWidgetRoundTripTests` keeps the two in sync.
nonisolated enum WidgetDeepLink {
    static let scheme = "lume"

    /// `lume://play/{movie|episode|live}/{catalogId}` — launches straight into
    /// playback with resume. The catalog id is percent-encoded: provider-derived
    /// ids can contain characters that are invalid in a URL path.
    static func play(kind: WidgetMediaItem.Kind, id: String) -> URL? {
        guard kind != .series else { return nil }
        return build(host: "play", kindSegment: kind.rawValue, id: id)
    }

    /// `lume://open/series/{catalogId}` — a series has no single playable URL,
    /// so favorites open its detail screen instead.
    static func openSeries(id: String) -> URL? {
        build(host: "open", kindSegment: "series", id: id)
    }

    private static func build(host: String, kindSegment: String, id: String) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "\(scheme)://\(host)/\(kindSegment)/\(escaped)")
    }
}
