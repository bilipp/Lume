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

    @Test func `recording server is a Lume Pro row in the playback group`() {
        let playback = SettingsCategory.grouped(hasConnectedServices: false).first { $0.group == .playback }
        #expect(playback?.categories == [.player, .downloads, .recordingServer])
        #expect(SettingsCategory.recordingServer.lockedFeature == .recordingServer)
        #expect(SettingsCategory.premium.lockedFeature == nil)
    }
}
