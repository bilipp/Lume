import Foundation
@testable import Lume
import Testing

struct LiveTVLayoutModeTests {
    private static func suiteName() -> String {
        "livetv.layout.test.\(UUID().uuidString)"
    }

    @Test func `the storage key stays stable`() {
        #expect(LiveTVLayoutMode.storageKey == "lume.liveTV.layoutMode")
    }

    @Test func `tvOS defaults to the Guide, everything else to the List`() {
        #expect(LiveTVLayoutMode.platformDefault(isTV: true) == .guide)
        #expect(LiveTVLayoutMode.platformDefault(isTV: false) == .list)
    }

    @Test func `the iOS host resolves to the List default`() {
        #expect(LiveTVLayoutMode.defaultMode == .list)
    }

    @Test func `a device that never picked follows the platform default`() throws {
        let name = Self.suiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let suite = try #require(UserDefaults(suiteName: name))
        let stored = suite.string(forKey: LiveTVLayoutMode.storageKey)
        #expect(stored == nil)
        #expect(LiveTVLayoutMode(storedValue: stored) == LiveTVLayoutMode.defaultMode)
    }

    @Test func `a stored choice wins over the default`() throws {
        let name = Self.suiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let suite = try #require(UserDefaults(suiteName: name))
        suite.set(LiveTVLayoutMode.guide.rawValue, forKey: LiveTVLayoutMode.storageKey)
        #expect(LiveTVLayoutMode(storedValue: suite.string(forKey: LiveTVLayoutMode.storageKey)) == .guide)
        suite.set(LiveTVLayoutMode.list.rawValue, forKey: LiveTVLayoutMode.storageKey)
        #expect(LiveTVLayoutMode(storedValue: suite.string(forKey: LiveTVLayoutMode.storageKey)) == .list)
    }

    @Test func `an unknown stored value falls back to the default`() throws {
        let name = Self.suiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let suite = try #require(UserDefaults(suiteName: name))
        suite.set("timeline", forKey: LiveTVLayoutMode.storageKey)
        #expect(LiveTVLayoutMode(storedValue: suite.string(forKey: LiveTVLayoutMode.storageKey)) == LiveTVLayoutMode.defaultMode)
        #expect(LiveTVLayoutMode(storedValue: "") == LiveTVLayoutMode.defaultMode)
    }

    @Test func `display names are the existing List and Guide keys`() {
        #expect(LiveTVLayoutMode.list.displayName == String(localized: "List"))
        #expect(LiveTVLayoutMode.guide.displayName == String(localized: "Guide"))
    }
}
