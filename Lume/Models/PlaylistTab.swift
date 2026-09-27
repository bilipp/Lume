import Foundation

/// A content tab a playlist can hide (Settings › Library › Tabs). Home, Search
/// and Settings always stay; Sports has its own app-wide switch.
nonisolated enum PlaylistTab: String, CaseIterable, Identifiable {
    case movies, series, liveTV

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
}

extension Playlist? {
    /// Whether `tab` shows in the tab bar for this (active) playlist. With no
    /// playlist every tab shows.
    func showsTab(_ tab: AppTab) -> Bool {
        guard let self else { return true }
        return !self.hiddenTabs.contains { $0.appTab == tab }
    }
}
