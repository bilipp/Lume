import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaylistTabTests {
    @Test func `encoding is order-independent so the same set never reads as a change`() {
        #expect(PlaylistTab.encode([.liveTV, .movies]) == "movies,liveTV")
        #expect(PlaylistTab.encode([.movies, .liveTV]) == "movies,liveTV")
        #expect(PlaylistTab.encode([]).isEmpty)
    }

    @Test func `decoding drops unknown entries written by a newer build`() {
        #expect(PlaylistTab.decode("series,podcasts,liveTV") == [.series, .liveTV])
        #expect(PlaylistTab.decode("").isEmpty)
    }

    @Test func `a playlist shows every tab until one is hidden`() {
        let playlist = Playlist(name: "P", serverURL: "http://x", username: "u", password: "p")
        let scope = CatalogScope.isolated(playlist.id)
        #expect(scope.visibleTabs(isolatedHidden: playlist.hiddenTabs).showsTab(.movies))

        playlist.hiddenTabs = [.movies]
        #expect(playlist.hiddenTabsRaw == "movies")
        let visible = scope.visibleTabs(isolatedHidden: playlist.hiddenTabs)
        #expect(!visible.showsTab(.movies))
        #expect(visible.showsTab(.series))
        // Tabs a playlist can't hide always show.
        #expect(visible.showsTab(.home))
        #expect(visible.showsTab(.search))
        #expect(visible.showsTab(.sports))
        #expect(visible.showsTab(.settings))
    }

    @Test func `a playlist is no combined member until it contributes a type`() {
        let playlist = Playlist(name: "P", serverURL: "http://x", username: "u", password: "p")
        #expect(playlist.combinedTabs.isEmpty)
        #expect(!playlist.isCombinedMember)
        #expect(playlist.combinedPriority == nil)

        playlist.combinedTabs = [.liveTV, .movies]
        #expect(playlist.combinedTypesRaw == "movies,liveTV")
        #expect(playlist.combinedTabs == [.movies, .liveTV])
        #expect(playlist.isCombinedMember)
    }

    @Test func `switching off every combined type keeps the priority`() {
        let playlist = Playlist(name: "P", serverURL: "http://x", username: "u", password: "p")
        playlist.combinedTabs = [.series]
        playlist.combinedPriority = 2

        playlist.combinedTabs = []
        #expect(playlist.combinedTypesRaw.isEmpty)
        #expect(!playlist.isCombinedMember)
        #expect(playlist.combinedPriority == 2)
    }

    @Test func `combined types read past entries a newer build wrote`() {
        let playlist = Playlist(name: "P", serverURL: "http://x", username: "u", password: "p")
        playlist.combinedTypesRaw = "series,podcasts"
        #expect(playlist.combinedTabs == [.series])
        #expect(playlist.isCombinedMember)
    }

    @Test func `no active playlist shows every tab`() {
        #expect(CatalogScope.empty.visibleTabs(isolatedHidden: []) == Set(PlaylistTab.allCases))
    }

    @Test func `combined shows a tab when any member contributes it`() {
        let first = UUID()
        let second = UUID()
        let scope = CatalogScope.combined([
            (id: first, tabs: [.liveTV]),
            (id: second, tabs: [.liveTV, .movies])
        ])
        #expect(scope.visibleTabs(isolatedHidden: []) == [.liveTV, .movies])
        #expect(!scope.visibleTabs(isolatedHidden: []).showsTab(.series))
        #expect(scope.visibleTabs(isolatedHidden: []).showsTab(.home))
    }

    @Test func `combined ignores the hidden tabs of an isolated playlist`() {
        let scope = CatalogScope.combined([
            (id: UUID(), tabs: [.series]),
            (id: UUID(), tabs: [.movies])
        ])
        // The priority-1 member's Settings › Library › Tabs choice applies only
        // while it is selected on its own.
        #expect(scope.visibleTabs(isolatedHidden: [.series, .movies]) == [.series, .movies])
    }

    @Test func `the visible-tab token changes only when the union does`() {
        let first = UUID()
        let second = UUID()
        let liveOnly = CatalogScope.combined([(id: first, tabs: [.liveTV]), (id: second, tabs: [.liveTV])])
        let reordered = CatalogScope.combined([(id: second, tabs: [.liveTV]), (id: first, tabs: [.liveTV])])
        let withMovies = CatalogScope.combined([(id: first, tabs: [.liveTV]), (id: second, tabs: [.movies])])

        let token = { (scope: CatalogScope) in PlaylistTab.encode(scope.visibleTabs(isolatedHidden: [])) }
        #expect(token(liveOnly) == "liveTV")
        #expect(token(reordered) == token(liveOnly))
        #expect(token(withMovies) == "movies,liveTV")
    }
}

struct SettingsCategoryTests {
    @Test func `the root follows the shared order and groups`() {
        let visible = SettingsCategory.visible(hasConnectedServices: true)
        #expect(visible.first == .premium)
        #expect(visible.starts(with: [.premium, .profiles, .playlists, .epg, .library]))
        #expect(visible.last == .developer)

        let grouped = SettingsCategory.grouped(hasConnectedServices: true)
        #expect(grouped.map(\.group) == SettingsCategoryGroup.allCases)
        #expect(grouped.first?.categories == [.premium, .profiles])
        #expect(grouped.first?.group.title == nil)
    }

    @Test func `connected services needs a configured service`() {
        #expect(!SettingsCategory.visible(hasConnectedServices: false).contains(.connectedServices))
        #expect(SettingsCategory.visible(hasConnectedServices: true).contains(.connectedServices))
    }

    @Test func `iOS offers appearance and downloads, and inlines help and about`() {
        let visible = SettingsCategory.visible(hasConnectedServices: false)
        #expect(visible.contains(.appearance))
        #expect(visible.contains(.downloads))
        // Help & Feedback and About are groups on the root list, not rows.
        #expect(!visible.contains(.help))
        #expect(!visible.contains(.about))
    }

    @Test func `live TV sits in the experience group between home and sports`() {
        let experience = SettingsCategory.grouped(hasConnectedServices: false).first { $0.group == .experience }
        #expect(experience?.categories == [.home, .liveTV, .sports, .appearance])
        let playback = SettingsCategory.grouped(hasConnectedServices: false).first { $0.group == .playback }
        #expect(playback?.categories == [.player, .downloads])
    }

    @Test func `a raw value from an older build resolves to nothing rather than crashing`() {
        // Nothing persists a category today; should anything ever, the
        // removed standalone Recording Server row must fail soft.
        #expect(SettingsCategory(rawValue: "recordingServer") == nil)
        #expect(SettingsCategory(rawValue: "liveTV") == .liveTV)
    }
}

struct RecordingSettingsAccessTests {
    @Test func `a free user with nothing paired hits the paywall on the server row`() {
        let access = RecordingSettingsAccess(isUnlocked: false, hasServers: false, isPaired: false)
        #expect(access.serverRowOpensPaywall)
        #expect(access.serverRowShowsBadge)
        #expect(!access.showsRecordingsRow)
    }

    @Test func `a lapsed subscriber keeps the paired server's page behind the crown`() {
        let access = RecordingSettingsAccess(isUnlocked: false, hasServers: true, isPaired: true)
        #expect(!access.serverRowOpensPaywall)
        #expect(access.serverRowShowsBadge)
        #expect(access.showsRecordingsRow)
        #expect(access.recordingsRowOpensPaywall)
    }

    @Test func `an unusable server row alone still opens the page to remove it`() {
        let access = RecordingSettingsAccess(isUnlocked: false, hasServers: true, isPaired: false)
        #expect(!access.serverRowOpensPaywall)
        #expect(!access.showsRecordingsRow)
    }

    @Test func `a subscriber opens everything without the crown`() {
        let unpaired = RecordingSettingsAccess(isUnlocked: true, hasServers: false, isPaired: false)
        #expect(!unpaired.serverRowOpensPaywall)
        #expect(!unpaired.serverRowShowsBadge)
        #expect(!unpaired.showsRecordingsRow)

        let paired = RecordingSettingsAccess(isUnlocked: true, hasServers: true, isPaired: true)
        #expect(paired.showsRecordingsRow)
        #expect(!paired.recordingsRowOpensPaywall)
    }

    @Test func `the tvOS rail lists Recordings only once switched on`() {
        #expect(RecordingServerSetup.showsRecordingsInLiveTVRailKey == "lume.liveTV.showsRecordingsInRail")
        #expect(RecordingServerSetup.showsRecordingsInLiveTVRailDefault == false)
    }

    @Test func `the iPhone and iPad toolbar buttons are opt-in`() {
        #expect(LiveTVToolbarSettings.showsRecordingsKey == "lume.liveTV.showsRecordingsInToolbar")
        #expect(LiveTVToolbarSettings.showsMultiViewKey == "lume.liveTV.showsMultiViewInToolbar")
        #expect(LiveTVToolbarSettings.showsRecordingsDefault == false)
        #expect(LiveTVToolbarSettings.showsMultiViewDefault == false)
    }

    @Test func `the Live TV settings strings are translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in [
            "Show in Live TV Sidebar",
            "Lists Recordings in the Live TV sidebar, below Favorites and Recently Watched.",
            "Live TV",
            "Layout",
            "Live TV Layout",
            "Recordings",
            "Recording Server",
            "Not paired",
            "Toolbar",
            "Multi-View",
            "Shows these buttons in the Live TV toolbar. Recordings appears once a recording server is paired."
        ] {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }

    @Test func `the Remove Server strings are translated in all nine locales`() throws {
        let catalog = try StringCatalog.localizable()
        for key in [
            "Remove Server",
            "Remove “%@”?",
            "Lume forgets this server on all your devices. Recordings and schedules stay on the server.",
            "Removing the server keeps its recordings and schedules on the server.",
            "Lume couldn't reach the server, so it may still list this device. Pair again or remove it there."
        ] {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }
}
