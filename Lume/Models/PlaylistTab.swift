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
    var disabledContent: Set<PlaylistTab> {
        get { PlaylistTab.decode(disabledContentRaw) }
        set { disabledContentRaw = PlaylistTab.encode(newValue) }
    }

    /// Whether a sync fetches `kind` for this playlist.
    func syncs(_ kind: PlaylistTab) -> Bool {
        !disabledContent.contains(kind)
    }

    /// The content kinds this playlist's source can carry at all: a file share
    /// and the media servers have no live channels, so their switch is moot.
    var selectableContent: [PlaylistTab] {
        PlaylistTab.allCases.filter { $0 != .liveTV || sourceType.canCarryLiveChannels }
    }
}

extension Playlist? {
    /// Whether `tab` shows in the tab bar for this (active) playlist: not when
    /// the playlist hides it, nor when it doesn't fetch that content. With no
    /// playlist every tab shows.
    func showsTab(_ tab: AppTab) -> Bool {
        guard let self else { return true }
        return !self.hiddenTabs.union(self.disabledContent).contains { $0.appTab == tab }
    }
}
