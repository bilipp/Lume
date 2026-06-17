//
//  WatchProvider.swift
//  Lume
//
//  Streaming-service ("watch provider") support. TMDB exposes which subscription
//  services a title is available on in a given country; Lume groups the library
//  by those services. The per-title `flatrate` provider ids live on Movie/Series
//  as a delimited string (see `WatchProviderIDs`); this catalog holds the
//  display metadata (name + logo) for the region's providers, used by the
//  Settings picker and the browse tiles.
//

import Foundation
import SwiftData

/// A streaming service in the local catalog, populated from TMDB's
/// region-scoped watch-provider list. Local-only, like the rest of the catalog.
@Model
final class WatchProvider {
    @Attribute(.unique) var id: Int
    var name: String
    /// TMDB relative logo path (e.g. `/abc.jpg`); render with
    /// `TMDBClient.providerLogoURL(_:)`.
    var logoPath: String?
    /// TMDB display priority for the region; lower sorts first.
    var displayPriority: Int

    init(id: Int, name: String, logoPath: String? = nil, displayPriority: Int = .max) {
        self.id = id
        self.name = name
        self.logoPath = logoPath
        self.displayPriority = displayPriority
    }
}

/// Encodes/decodes the set of watch-provider ids stored on a title.
///
/// SwiftData can't query into a stored `[Int]`, so the ids are persisted as a
/// pipe-delimited string with sentinels (`|8|337|`). The sentinels let a
/// `localizedStandardContains("|8|")` predicate narrow rows in SQLite without
/// `|8|` matching `|80|` — the same trick `GenreParser` uses for genre tokens.
enum WatchProviderIDs {
    /// `nil` for an empty list so the column stays clean and the
    /// `watchProviderIdsRaw != nil` derivation fetch skips un-enriched rows.
    static func encode(_ ids: [Int]) -> String? {
        var seen = Set<Int>()
        let ordered = ids.filter { seen.insert($0).inserted }
        guard !ordered.isEmpty else { return nil }
        return "|" + ordered.map(String.init).joined(separator: "|") + "|"
    }

    static func decode(_ raw: String?) -> [Int] {
        guard let raw else { return [] }
        return raw.split(separator: "|").compactMap { Int($0) }
    }

    /// The SQLite-narrowing token for a single provider id (`|8|`).
    static func queryToken(for id: Int) -> String {
        "|\(id)|"
    }

    /// Whether `raw` carries `id` as a whole token. Used to re-filter a
    /// `localizedStandardContains` fetch down to exact matches.
    static func contains(_ raw: String?, id: Int) -> Bool {
        decode(raw).contains(id)
    }
}

/// A watch-provider browse destination, carried as a navigation value so the
/// Movies and Series tabs can each register a `navigationDestination` for it.
/// Mirrors `GenreSelection`.
struct WatchProviderSelection: Hashable {
    let providerId: Int
    let name: String
    let type: CategoryType
}
