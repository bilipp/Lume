//
//  TabLayoutSettingsTests.swift
//  LumeTests
//
//  Tab order resolution, the visible tab set and the landing tab.
//

import Foundation
@testable import Lume
import Testing

struct TabLayoutSettingsTests {
    private let defaultOrder: [MainTab] = [.home, .movies, .series, .liveTV, .sports]
    private let allContent = Set(PlaylistTab.allCases)

    // MARK: - resolve

    @Test func `empty resolves to default order`() {
        #expect(TabLayoutSettings.resolve(orderRaw: "") == defaultOrder)
    }

    @Test func `unknown entries are dropped`() {
        #expect(TabLayoutSettings.resolve(orderRaw: "sports,bogus,home,,movies,series,liveTV")
            == [.sports, .home, .movies, .series, .liveTV])
    }

    @Test func `duplicates keep first position`() {
        #expect(TabLayoutSettings.resolve(orderRaw: "liveTV,home,liveTV,movies,home,series,sports")
            == [.liveTV, .home, .movies, .series, .sports])
    }

    @Test func `missing tabs append in default order`() {
        #expect(TabLayoutSettings.resolve(orderRaw: "sports,series") == [.sports, .series, .home, .movies, .liveTV])
    }

    @Test func `encode round trips`() {
        let order: [MainTab] = [.liveTV, .sports, .home, .series, .movies]
        #expect(TabLayoutSettings.resolve(orderRaw: TabLayoutSettings.encode(order)) == order)
    }

    // MARK: - visible

    @Test func `everything on keeps order`() {
        let order: [MainTab] = [.sports, .liveTV, .home, .movies, .series]
        let visible = TabLayoutSettings.visible(order: order, content: allContent, homeEnabled: true, sportsEnabled: true)
        #expect(visible == order)
    }

    @Test func `home hidden when disabled and content shows`() {
        let visible = TabLayoutSettings.visible(
            order: defaultOrder, content: [.movies], homeEnabled: false, sportsEnabled: true
        )
        #expect(visible == [.movies, .sports])
    }

    @Test func `home forced when no content tab shows`() {
        let visible = TabLayoutSettings.visible(
            order: [.sports, .movies, .home, .series, .liveTV], content: [], homeEnabled: false, sportsEnabled: true
        )
        #expect(visible == [.sports, .home])
        #expect(TabLayoutSettings.homeIsForced(content: []))
        #expect(!TabLayoutSettings.homeIsForced(content: [.liveTV]))
    }

    @Test func `sports off is dropped`() {
        let visible = TabLayoutSettings.visible(
            order: defaultOrder, content: allContent, homeEnabled: true, sportsEnabled: false
        )
        #expect(visible == [.home, .movies, .series, .liveTV])
    }

    @Test func `hidden content tabs are dropped`() {
        let visible = TabLayoutSettings.visible(
            order: [.liveTV, .series, .movies, .home, .sports], content: [.movies, .liveTV],
            homeEnabled: true, sportsEnabled: true
        )
        #expect(visible == [.liveTV, .movies, .home, .sports])
    }

    // MARK: - landingTab

    @Test func `landing is first visible tab`() {
        #expect(TabLayoutSettings.landingTab(visible: [.liveTV, .home]) == .liveTV)
        #expect(TabLayoutSettings.landingTab(visible: defaultOrder) == .home)
    }

    @Test func `landing falls back to search`() {
        #expect(TabLayoutSettings.landingTab(visible: []) == .search)
    }

    @MainActor
    @Test func `stored landing reads the saved layout`() throws {
        let suite = "TabLayoutSettingsTests.storedLanding"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TabLayoutSettings.storedLandingTab(defaults: defaults) == .home)

        defaults.set("sports,liveTV", forKey: TabLayoutSettings.orderKey)
        defaults.set(true, forKey: SportsSyncService.tabEnabledKey)
        #expect(TabLayoutSettings.storedLandingTab(defaults: defaults) == .sports)

        defaults.set(false, forKey: SportsSyncService.tabEnabledKey)
        #expect(TabLayoutSettings.storedLandingTab(defaults: defaults) == .liveTV)

        defaults.set("home,movies", forKey: TabLayoutSettings.orderKey)
        defaults.set(false, forKey: TabLayoutSettings.homeEnabledKey)
        #expect(TabLayoutSettings.storedLandingTab(defaults: defaults) == .movies)
    }

    // MARK: - Settings list

    @Test func `content tabs listed only with content`() {
        #expect(TabLayoutSettings.listedTabs(orderRaw: "sports,liveTV", showsContent: true)
            == [.sports, .liveTV, .home, .movies, .series])
        #expect(TabLayoutSettings.listedTabs(orderRaw: "sports,liveTV", showsContent: false) == [.sports, .home])
    }

    @Test func `reorder keeps unlisted tabs in their slots`() {
        let listed: [MainTab] = [.home, .sports]
        let raw = TabLayoutSettings.reordered(orderRaw: "", listed: listed, moved: [.sports, .home])
        #expect(TabLayoutSettings.resolve(orderRaw: raw) == [.sports, .movies, .series, .liveTV, .home])
    }

    @Test func `default needs default order and home on`() {
        #expect(TabLayoutSettings.isDefault(orderRaw: "", homeEnabled: true))
        #expect(TabLayoutSettings.isDefault(orderRaw: "home,movies", homeEnabled: true))
        #expect(!TabLayoutSettings.isDefault(orderRaw: "", homeEnabled: false))
        #expect(!TabLayoutSettings.isDefault(orderRaw: "sports", homeEnabled: true))
    }
}
