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

    @Test func `every platform defaults to the Guide`() {
        #expect(LiveTVLayoutMode.defaultMode == .guide)
    }

    @Test func `a device that never picked gets the Guide`() throws {
        let name = Self.suiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let suite = try #require(UserDefaults(suiteName: name))
        let stored = suite.string(forKey: LiveTVLayoutMode.storageKey)
        #expect(stored == nil)
        #expect(LiveTVLayoutMode(storedValue: stored) == .guide)
    }

    @Test func `a device that picked the List keeps it after the default changed`() throws {
        let name = Self.suiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let suite = try #require(UserDefaults(suiteName: name))
        suite.set(LiveTVLayoutMode.list.rawValue, forKey: LiveTVLayoutMode.storageKey)
        #expect(LiveTVLayoutMode(storedValue: suite.string(forKey: LiveTVLayoutMode.storageKey)) == .list)
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
