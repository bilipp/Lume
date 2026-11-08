import Foundation

/// A content tab a playlist can hide (Settings › Library › Tabs), and the
/// content kind a playlist can stop fetching (its Content switches). Home,
/// Search and Settings always stay; Sports has its own app-wide switch.
nonisolated enum PlaylistTab: String, CaseIterable, Identifiable {
    case movies, series, liveTV

    /// The catalog category type this kind's rows file under.
    var categoryType: CategoryType {
        switch self {
        case .movies: .vod
        case .series: .series
        case .liveTV: .live
        }
    }

    var id: String {
        rawValue
    }

    var appTab: AppTab {
        switch self {
        case .movies: .movies
        case .series: .series
        case .liveTV: .liveTV
        }
    }

    /// Comma-separated raw values, unknown entries dropped so a value written
    /// by a newer build still reads.
    static func decode(_ raw: String) -> Set<PlaylistTab> {
        Set(raw.split(separator: ",").compactMap { PlaylistTab(rawValue: String($0)) })
    }

    /// Declaration order, so the same set always encodes to the same string and
    /// the iCloud merge never sees a spurious change.
    static func encode(_ tabs: Set<PlaylistTab>) -> String {
        allCases.filter(tabs.contains).map(\.rawValue).joined(separator: ",")
    }
}

extension Playlist {
    var hiddenTabs: Set<PlaylistTab> {
        get { PlaylistTab.decode(hiddenTabsRaw) }
        set { hiddenTabsRaw = PlaylistTab.encode(newValue) }
    }

    /// The content kinds this playlist does not fetch. A sync skips them and
    /// removes what an earlier sync brought in; their tabs are hidden too.
    nonisolated var disabledContent: Set<PlaylistTab> {
        get { PlaylistTab.decode(disabledContentRaw) }
        set { disabledContentRaw = PlaylistTab.encode(newValue) }
    }

    /// Whether a sync fetches `kind` for this playlist.
    nonisolated func syncs(_ kind: PlaylistTab) -> Bool {
        !disabledContent.contains(kind)
    }

    /// The tabs an isolated playlist keeps out of the tab bar: the ones it
    /// hides, and the content it doesn't fetch.
    var tabsOutOfView: Set<PlaylistTab> {
        hiddenTabs.union(disabledContent)
    }

    /// The types this playlist contributes to Combined: its choice there, less
    /// the content it doesn't fetch (it has no rows of that kind).
    nonisolated var combinedContribution: Set<PlaylistTab> {
        combinedTabs.subtracting(disabledContent)
    }

    /// The content kinds this playlist's source can carry at all: a file share
    /// and the media servers have no live channels, so their switch is moot.
    var selectableContent: [PlaylistTab] {
        PlaylistTab.allCases.filter { $0 != .liveTV || sourceType.canCarryLiveChannels }
    }

    nonisolated var combinedTabs: Set<PlaylistTab> {
        get { PlaylistTab.decode(combinedTypesRaw) }
        set { combinedTypesRaw = PlaylistTab.encode(newValue) }
    }

    nonisolated var isCombinedMember: Bool {
        !combinedTabs.isEmpty
    }
}

nonisolated extension CatalogScope {
    /// The content tabs in the tab bar. An isolated playlist shows every tab it
    /// doesn't hide (Settings › Library › Tabs); Combined shows every type at
    /// least one member contributes, and no playlist's hidden tabs apply. With
    /// no playlist at all every tab shows.
    func visibleTabs(isolatedHidden hidden: Set<PlaylistTab>) -> Set<PlaylistTab> {
        guard isCombined else { return Set(PlaylistTab.allCases).subtracting(hidden) }
        return Set(PlaylistTab.allCases.filter { !members(for: $0).isEmpty })
    }
}

nonisolated extension Set<PlaylistTab> {
    /// Whether `tab` is in the tab bar. Home, Search, Sports and Settings are
    /// no playlist's to hide.
    func showsTab(_ tab: AppTab) -> Bool {
        guard let playlistTab = PlaylistTab.allCases.first(where: { $0.appTab == tab }) else { return true }
        return contains(playlistTab)
    }
}

nonisolated extension PlaylistTab {
    /// The tab's name inside a sentence — VoiceOver labels naming a playlist.
    var spokenName: String {
        switch self {
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        case .liveTV: String(localized: "Live TV")
        }
    }
}

extension Set<PlaylistTab> {
    /// The tabs in declaration order, for a member row's subtitle.
    var summary: String {
        let names = PlaylistTab.allCases.filter(contains).map(\.spokenName)
        return names.isEmpty ? "—" : names.joined(separator: " · ")
    }
}
