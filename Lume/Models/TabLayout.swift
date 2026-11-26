import SwiftUI

/// A tab the user can move in Settings › Library › Tabs. Search keeps its
/// system position; on tvOS Settings and Sync stay last.
nonisolated enum MainTab: String, CaseIterable, Identifiable {
    /// Raw values are stored in `TabLayoutSettings.orderKey`; never rename them.
    case home, movies, series, liveTV, sports

    var id: String {
        rawValue
    }

    init(_ playlistTab: PlaylistTab) {
        switch playlistTab {
        case .movies: self = .movies
        case .series: self = .series
        case .liveTV: self = .liveTV
        }
    }

    init?(appTab: AppTab) {
        guard let tab = Self.allCases.first(where: { $0.appTab == appTab }) else { return nil }
        self = tab
    }

    var appTab: AppTab {
        if let playlistTab { return playlistTab.appTab }
        return self == .home ? .home : .sports
    }

    /// The playlist-hideable tab this is, nil for Home and Sports.
    var playlistTab: PlaylistTab? {
        PlaylistTab.allCases.first { Self($0) == self }
    }

    var title: LocalizedStringKey {
        LocalizedStringKey(spokenName)
    }

    /// The tab's name inside a sentence, for VoiceOver labels.
    var spokenName: String {
        if let playlistTab { return playlistTab.spokenName }
        return self == .home ? String(localized: "Home") : String(localized: "Sports")
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .series: "tv"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .sports: "sportscourt"
        }
    }
}

/// App-wide, device-local tab order and Home switch. Never synced.
nonisolated enum TabLayoutSettings {
    static let orderKey = "tabs.order.v1"
    static let homeEnabledKey = "tabs.homeEnabled"
    static let homeEnabledDefault = true

    /// The stored order, complete and de-duplicated. Mirrors
    /// `HomeLayoutSettings.resolve`.
    static func resolve(orderRaw: String) -> [MainTab] {
        normalized(decode(orderRaw))
    }

    /// The comma-separated raw value as tabs, unknown entries dropped.
    static func decode(_ raw: String) -> [MainTab] {
        raw.split(separator: ",").compactMap { MainTab(rawValue: String($0)) }
    }

    static func encode(_ order: [MainTab]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// `order` with duplicates dropped and any missing tab appended in
    /// declaration order.
    static func normalized(_ order: [MainTab]) -> [MainTab] {
        var seen = Set<MainTab>()
        return (order + MainTab.allCases).filter { seen.insert($0).inserted }
    }

    static func isDefault(orderRaw: String, homeEnabled: Bool) -> Bool {
        resolve(orderRaw: orderRaw) == MainTab.allCases && homeEnabled
    }

    static func reset(orderRaw: inout String, homeEnabled: inout Bool) {
        orderRaw = ""
        homeEnabled = true
    }

    /// The tabs Settings lists, in the stored order. Content tabs need a
    /// playlist to belong to, or Combined View.
    static func listedTabs(orderRaw: String, showsContent: Bool) -> [MainTab] {
        resolve(orderRaw: orderRaw).filter { $0.playlistTab == nil || showsContent }
    }

    /// The stored order after the listed rows were rearranged to `moved`;
    /// tabs not listed keep their slots.
    static func reordered(orderRaw: String, listed: [MainTab], moved: [MainTab]) -> String {
        let listedSet = Set(listed)
        var next = moved.makeIterator()
        let order = resolve(orderRaw: orderRaw).map { tab in
            listedSet.contains(tab) ? next.next() ?? tab : tab
        }
        return encode(order)
    }

    /// The footer notes both Settings screens show under the tab list.
    static func footerNotes(homeForced: Bool, homeEnabled: Bool, sportsEnabled: Bool) -> [String] {
        var notes: [String] = []
        if homeForced {
            notes.append(String(localized: "Home stays on while no Movies, Series or Live TV tab is shown."))
        }
        if !homeEnabled, !homeForced, !sportsEnabled {
            notes.append(String(localized: "With Home and Sports both off, the Sports hub can't be opened."))
        }
        return notes
    }

    /// Home can't be switched off while no content tab shows: Settings is only
    /// reachable from Home or a content tab on iOS, macOS and visionOS.
    static func homeIsForced(content: Set<PlaylistTab>) -> Bool {
        content.isEmpty
    }

    /// The tabs in the bar, in `order`. `content` is the set of content tabs
    /// the active scope shows.
    static func visible(
        order: [MainTab],
        content: Set<PlaylistTab>,
        homeEnabled: Bool,
        sportsEnabled: Bool
    ) -> [MainTab] {
        order.filter { tab in
            switch tab {
            case .home: homeEnabled || homeIsForced(content: content)
            case .sports: sportsEnabled
            case .movies, .series, .liveTV: tab.playlistTab.map(content.contains) ?? false
            }
        }
    }

    static func landingTab(visible: [MainTab]) -> AppTab {
        visible.first?.appTab ?? .search
    }

    /// The landing tab before the playlists load: every content tab counts as
    /// shown, and `MainTabView` corrects it once they have.
    @MainActor
    static func storedLandingTab(defaults: UserDefaults = .standard) -> AppTab {
        let visible = visible(
            order: resolve(orderRaw: defaults.string(forKey: orderKey) ?? ""),
            content: Set(PlaylistTab.allCases),
            homeEnabled: defaults.object(forKey: homeEnabledKey) as? Bool ?? homeEnabledDefault,
            sportsEnabled: defaults.object(forKey: SportsSyncService.tabEnabledKey) as? Bool
                ?? SportsSyncService.tabEnabledDefault
        )
        return landingTab(visible: visible)
    }
}
