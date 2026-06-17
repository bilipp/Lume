//
//  HomeLayoutSettings.swift
//  Lume
//
//  User preferences for the Home screen layout: which rows appear and in what
//  order. The order is a small scalar (a comma-separated list of section keys),
//  so UserDefaults (via @AppStorage) is the right home — mirroring the
//  `PlayerEnginePriority` ordering used for the playback engines.
//

import SwiftUI

/// A reorderable row on the Home screen. The raw value is the stable key stored
/// in the user's section order, so cases must not be renamed once shipped.
enum HomeSection: String, CaseIterable, Identifiable {
    case recentlyWatched
    case favorites
    case forYou
    case trendingMovies
    case trendingSeries
    case traktWatchlist

    var id: String {
        rawValue
    }

    /// The label shown in the Home layout settings. Mirrors the row's own header
    /// on Home (the Trakt row is shortened from "From Your Trakt Watchlist").
    var title: LocalizedStringKey {
        switch self {
        case .recentlyWatched: "Recently Watched"
        case .favorites: "Favorites"
        case .forYou: "For You"
        case .trendingMovies: "Trending Movies"
        case .trendingSeries: "Trending Series"
        case .traktWatchlist: "Trakt Watchlist"
        }
    }

    /// The same label as a resolved `String`, for places that interpolate it
    /// (e.g. accessibility labels) where a `LocalizedStringKey` can't be used.
    /// References the same catalog keys as `title`.
    var displayName: String {
        switch self {
        case .recentlyWatched: String(localized: "Recently Watched")
        case .favorites: String(localized: "Favorites")
        case .forYou: String(localized: "For You")
        case .trendingMovies: String(localized: "Trending Movies")
        case .trendingSeries: String(localized: "Trending Series")
        case .traktWatchlist: String(localized: "Trakt Watchlist")
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyWatched: "clock.arrow.circlepath"
        case .favorites: "star"
        case .forYou: "sparkles"
        case .trendingMovies: "film"
        case .trendingSeries: "tv"
        case .traktWatchlist: "rectangle.stack.badge.play"
        }
    }
}

/// The order of the Home rows, top to bottom. Each section still only renders
/// when it has something to show (and "For You" additionally honours the
/// recommendations toggle, see `RecommendationSettings`). Persisted as a
/// comma-separated list of `HomeSection` raw values under `sectionOrderKey`.
enum HomeLayoutSettings {
    /// Stored section order. Empty until the user reorders, in which case
    /// `resolve` falls back to the declaration order of `HomeSection`.
    static let sectionOrderKey = "home.sectionOrder.v1"

    /// Sections the user has switched off, as a comma-separated list of raw
    /// values. Absence means enabled, so the default (empty) shows every
    /// section. `.forYou` is intentionally NOT tracked here — its on/off state
    /// is the opt-in `RecommendationSettings.enabledKey`, which also gates the
    /// (expensive) recommendation recompute on Home.
    static let disabledSectionsKey = "home.disabledSections.v1"

    static func decodeDisabled(_ raw: String) -> Set<HomeSection> {
        Set(raw.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) })
    }

    /// Encode the disabled set in a stable order so the stored value (and its
    /// iCloud-synced @AppStorage) doesn't churn as the set is mutated.
    static func encodeDisabled(_ sections: Set<HomeSection>) -> String {
        sections.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Whether `section` should render. Not meaningful for `.forYou` (see
    /// `disabledSectionsKey`); callers handle that case via `RecommendationSettings`.
    static func isEnabled(_ section: HomeSection, disabledRaw: String) -> Bool {
        !decodeDisabled(disabledRaw).contains(section)
    }

    /// Decode the stored order into a complete, de-duplicated section list,
    /// falling back to the declaration order when nothing has been stored yet.
    static func resolve(orderRaw: String) -> [HomeSection] {
        normalized(decode(orderRaw))
    }

    /// Parse the comma-separated raw value into sections, dropping any token
    /// that doesn't name a known section.
    static func decode(_ raw: String) -> [HomeSection] {
        raw.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) }
    }

    static func encode(_ list: [HomeSection]) -> String {
        list.map(\.rawValue).joined(separator: ",")
    }

    /// Keep the given order but ensure every section appears exactly once: drop
    /// duplicates, then append any section missing from the list in declaration
    /// order. Guarantees the order is always complete even after a new section
    /// is added to `HomeSection` once the user has stored their order.
    static func normalized(_ order: [HomeSection]) -> [HomeSection] {
        var seen = Set<HomeSection>()
        var result: [HomeSection] = []
        for section in order where seen.insert(section).inserted {
            result.append(section)
        }
        for section in HomeSection.allCases where seen.insert(section).inserted {
            result.append(section)
        }
        return result
    }
}
