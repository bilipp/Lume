//
//  WhatsNewTests.swift
//  LumeTests
//
//  When an update raises the What's New sheet, and a lint over the catalog
//  every release adds to.
//

import Foundation
@testable import Lume
import Testing
import UIKit

@Suite("What’s New")
@MainActor
struct WhatsNewTests {
    private static func item(_ id: String, platforms: Set<WhatsNewPlatform> = Set(WhatsNewPlatform.allCases)) -> WhatsNewItem {
        WhatsNewItem(id: id, symbol: "star", title: "Title", summary: "Summary", platforms: platforms)
    }

    private static let releases = [
        WhatsNewRelease(version: AppVersion(3, 3), highlights: [item("3.3.a")]),
        WhatsNewRelease(version: AppVersion(3, 2), highlights: [], notes: ["Fixes"]),
        WhatsNewRelease(version: AppVersion(3, 1), highlights: [item("3.1.a"), item("3.1.tv", platforms: [.tvOS])]),
        WhatsNewRelease(version: AppVersion(3, 0), highlights: [item("3.0.mac", platforms: [.macOS])])
    ]

    private func present(lastSeen: AppVersion?, current: AppVersion, platform: WhatsNewPlatform = .iOS) -> AppVersion? {
        WhatsNewPolicy.releaseToPresent(lastSeen: lastSeen, current: current, releases: Self.releases, platform: platform)?.version
    }

    // MARK: - Version

    @Test func `versions parse and compare by part`() throws {
        #expect(AppVersion("3.2.1") == AppVersion(3, 2, 1))
        #expect(AppVersion("3.2") == AppVersion(3, 2))
        #expect(AppVersion("3") == AppVersion(3, 0))
        #expect(try #require(AppVersion("3.10.0")) > AppVersion(3, 9, 9))
        #expect(AppVersion(3, 2, 1).feature == AppVersion(3, 2))
        #expect(AppVersion(3, 2).displayString == "3.2")
        #expect(AppVersion(3, 2, 1).displayString == "3.2.1")
    }

    @Test(arguments: ["—", "", "3.x", "3..1", "1.2.3.4", "-1.0"])
    func `anything that is not a version is rejected`(raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    // MARK: - Policy

    @Test func `an update to a release with highlights shows it`() {
        #expect(present(lastSeen: AppVersion(3, 2), current: AppVersion(3, 3)) == AppVersion(3, 3))
    }

    @Test func `a patch update shows nothing`() {
        #expect(present(lastSeen: AppVersion(3, 3), current: AppVersion(3, 3, 1)) == nil)
    }

    @Test func `a patch of the release still shows it to someone coming from the one before`() {
        #expect(present(lastSeen: AppVersion(3, 2, 4), current: AppVersion(3, 3, 2)) == AppVersion(3, 3))
    }

    @Test func `a release without highlights shows nothing`() {
        #expect(present(lastSeen: AppVersion(3, 1), current: AppVersion(3, 2)) == nil)
    }

    @Test func `skipping releases shows only the newest one with highlights`() {
        #expect(present(lastSeen: AppVersion(3, 0), current: AppVersion(3, 3)) == AppVersion(3, 3))
        #expect(present(lastSeen: AppVersion(3, 0), current: AppVersion(3, 2)) == AppVersion(3, 1))
    }

    @Test func `a release the build doesn't contain yet is never shown`() {
        #expect(present(lastSeen: AppVersion(3, 1), current: AppVersion(3, 2, 5)) == nil)
    }

    @Test func `an install that predates the feature gets the release it updated to and nothing older`() {
        #expect(present(lastSeen: nil, current: AppVersion(3, 3)) == AppVersion(3, 3))
        #expect(present(lastSeen: nil, current: AppVersion(3, 2)) == nil)
    }

    @Test func `highlights of another platform don't raise the sheet`() {
        #expect(present(lastSeen: AppVersion(2, 9), current: AppVersion(3, 0), platform: .iOS) == nil)
        #expect(present(lastSeen: AppVersion(2, 9), current: AppVersion(3, 0), platform: .macOS) == AppVersion(3, 0))
        #expect(Self.releases[2].highlights(on: .iOS).map(\.id) == ["3.1.a"])
        #expect(Self.releases[2].highlights(on: .tvOS).map(\.id) == ["3.1.a", "3.1.tv"])
    }

    // MARK: - Coordinator

    private func makeStore() throws -> WhatsNewStore {
        let suite = "whatsNew.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return WhatsNewStore(defaults: defaults)
    }

    private func makeCoordinator(store: WhatsNewStore, current: AppVersion?) -> WhatsNewCoordinator {
        WhatsNewCoordinator(store: store, releases: Self.releases, current: current, platform: .iOS)
    }

    @Test func `a fresh install records its version and shows nothing`() throws {
        let store = try makeStore()
        let coordinator = makeCoordinator(store: store, current: AppVersion(3, 3))
        coordinator.noteLaunch(isFreshInstall: true, mode: .normal)
        #expect(coordinator.pending == nil)
        #expect(store.lastSeenVersion == AppVersion(3, 3))
    }

    @Test func `an existing install sees the introducing release once`() throws {
        let store = try makeStore()
        let first = makeCoordinator(store: store, current: AppVersion(3, 3))
        first.noteLaunch(isFreshInstall: false, mode: .normal)
        #expect(first.pending?.version == AppVersion(3, 3))
        #expect(store.lastSeenVersion == nil)

        #expect(first.claim()?.version == AppVersion(3, 3))
        #expect(first.claim() == nil)
        first.noteSheetAppeared()
        #expect(first.didPresentThisLaunch)
        #expect(store.lastSeenVersion == AppVersion(3, 3))

        let second = makeCoordinator(store: store, current: AppVersion(3, 3))
        second.noteLaunch(isFreshInstall: false, mode: .normal)
        #expect(second.pending == nil)
    }

    @Test func `a launch deferred for playback offers the release again next time`() throws {
        let store = try makeStore()
        store.lastSeenVersion = AppVersion(3, 2)
        let first = makeCoordinator(store: store, current: AppVersion(3, 3))
        first.noteLaunch(isFreshInstall: false, mode: .normal)
        first.deferToNextLaunch()
        #expect(first.pending == nil)
        #expect(store.lastSeenVersion == AppVersion(3, 2))

        let second = makeCoordinator(store: store, current: AppVersion(3, 3))
        second.noteLaunch(isFreshInstall: false, mode: .normal)
        #expect(second.pending?.version == AppVersion(3, 3))
    }

    @Test func `an update with nothing to show still moves the seen version on`() throws {
        let store = try makeStore()
        store.lastSeenVersion = AppVersion(3, 1)
        let coordinator = makeCoordinator(store: store, current: AppVersion(3, 2))
        coordinator.noteLaunch(isFreshInstall: false, mode: .normal)
        #expect(coordinator.pending == nil)
        #expect(store.lastSeenVersion == AppVersion(3, 2))
    }

    @Test func `automated runs show nothing and store nothing`() throws {
        let store = try makeStore()
        let coordinator = makeCoordinator(store: store, current: AppVersion(3, 3))
        coordinator.noteLaunch(isFreshInstall: false, mode: .disabled)
        #expect(coordinator.pending == nil)
        #expect(store.lastSeenVersion == nil)
    }

    @Test func `a UI test can force the newest release`() throws {
        let store = try makeStore()
        store.lastSeenVersion = AppVersion(3, 3)
        let coordinator = makeCoordinator(store: store, current: AppVersion(3, 3))
        coordinator.noteLaunch(isFreshInstall: true, mode: .forced)
        #expect(coordinator.pending?.version == AppVersion(3, 3))
    }

    @Test func `a build without a readable version does nothing`() throws {
        let store = try makeStore()
        let coordinator = makeCoordinator(store: store, current: nil)
        coordinator.noteLaunch(isFreshInstall: false, mode: .normal)
        #expect(coordinator.pending == nil)
        #expect(store.lastSeenVersion == nil)
    }

    // MARK: - Catalog

    @Test func `releases are listed newest first, one per feature version`() {
        let versions = WhatsNewCatalog.releases.map(\.version)
        #expect(versions == versions.sorted(by: >))
        #expect(Set(versions.map(\.feature)).count == versions.count)
        #expect(versions.allSatisfy { $0.patch == 0 })
    }

    @Test func `the history lists only releases the build contains, with content on the platform`() {
        let history = WhatsNewCatalog.history(for: AppVersion(3, 2, 1), on: .iOS, releases: Self.releases)
        #expect(history.map(\.version) == [AppVersion(3, 2), AppVersion(3, 1)])
        let mac = WhatsNewCatalog.history(for: AppVersion(3, 0), on: .macOS, releases: Self.releases)
        #expect(mac.map(\.version) == [AppVersion(3, 0)])
    }

    @Test func `item ids are unique and carry their release`() {
        let items = WhatsNewCatalog.releases.flatMap { release in release.highlights.map { (release, $0) } }
        #expect(Set(items.map(\.1.id)).count == items.count)
        for (release, item) in items {
            #expect(item.id.hasPrefix("\(release.version.displayString)."), "\(item.id) is filed under \(release.version.displayString)")
            #expect(!item.platforms.isEmpty, "\(item.id) is on no platform")
        }
    }

    /// The tvOS cover doesn't scroll, and a sheet with more than five rows is
    /// a changelog, not a highlight reel.
    @Test func `no platform gets more than five highlights in a release`() {
        for release in WhatsNewCatalog.releases {
            for platform in WhatsNewPlatform.allCases {
                #expect(release.highlights(on: platform).count <= 5, "\(release.version.displayString) on \(platform)")
            }
        }
    }

    @Test func `every symbol exists`() {
        for item in WhatsNewCatalog.releases.flatMap(\.highlights) {
            #expect(UIImage(systemName: item.symbol) != nil, "\(item.id) uses unknown symbol \(item.symbol)")
        }
    }

    @Test func `every string is translated in all shipping locales`() throws {
        let catalog = try StringCatalog.table("WhatsNew")
        let chrome = ["What’s New", "What’s New in Lume", "All Release Notes"]
        let content = WhatsNewCatalog.releases.flatMap { release in
            release.highlights.flatMap { [$0.title.key, $0.summary.key] } + release.notes.map(\.key)
        }
        for key in chrome + content {
            expectTranslatedEverywhere(key, in: catalog)
        }
        #expect(Set(catalog.keys) == Set(chrome + content), "WhatsNew.xcstrings and WhatsNewCatalog list different strings")
    }
}
