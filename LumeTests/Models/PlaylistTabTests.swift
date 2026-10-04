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
        #expect(Optional(playlist).showsTab(.movies))

        playlist.hiddenTabs = [.movies]
        #expect(playlist.hiddenTabsRaw == "movies")
        #expect(!Optional(playlist).showsTab(.movies))
        #expect(Optional(playlist).showsTab(.series))
        // Tabs a playlist can't hide always show.
        #expect(Optional(playlist).showsTab(.home))
        #expect(Optional(playlist).showsTab(.search))
    }

    @Test func `no active playlist shows every tab`() {
        let none: Playlist? = nil
        #expect(none.showsTab(.liveTV))
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
            "Not paired"
        ] {
            expectTranslatedEverywhere(key, in: catalog)
        }
    }
}
