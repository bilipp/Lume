import Foundation
@testable import Lume
import Testing

struct TopShelfSettingsTests {
    /// A throwaway defaults domain per test, so nothing leaks into
    /// `UserDefaults.standard` or across tests.
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TopShelfSettingsTests-\(UUID().uuidString)"))
    }

    @Test func `nothing stored resolves to the default configuration`() throws {
        #expect(try TopShelfSettings.configuration(defaults: makeDefaults()) == .default)
    }

    @Test func `stored choices come back as the configuration`() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: TopShelfSettings.enabledKey)
        defaults.set("carousel", forKey: TopShelfSettings.styleKey)
        defaults.set(20, forKey: TopShelfSettings.itemsPerSectionKey)
        defaults.set("favorites,continueWatching", forKey: TopShelfSettings.sectionOrderKey)
        defaults.set("favorites", forKey: TopShelfSettings.disabledSectionsKey)

        let configuration = TopShelfSettings.configuration(defaults: defaults)
        #expect(!configuration.isEnabled)
        #expect(configuration.style == .carousel)
        #expect(configuration.itemsPerSection == 20)
        // The stored order, minus the switched-off section.
        #expect(configuration.sections == [.continueWatching])
    }

    @Test func `unknown stored values fall back`() throws {
        let defaults = try makeDefaults()
        defaults.set("mosaic", forKey: TopShelfSettings.styleKey)
        defaults.set(7, forKey: TopShelfSettings.itemsPerSectionKey)
        defaults.set("bogus,favorites,favorites", forKey: TopShelfSettings.sectionOrderKey)

        let configuration = TopShelfSettings.configuration(defaults: defaults)
        #expect(configuration.style == .sectioned)
        #expect(configuration.itemsPerSection == TopShelfConfiguration.default.itemsPerSection)
        // Unknown and repeated names dropped, the missing section appended.
        #expect(configuration.sections == [.favorites, .continueWatching])
    }

    @Test func `the snapshot carries enough items for the largest section`() {
        #expect(TopShelfConfiguration.maxItemsPerSection >= TopShelfConfiguration.itemCountChoices.max() ?? 0)
        #expect(TopShelfConfiguration.itemCountChoices.contains(TopShelfConfiguration.default.itemsPerSection))
    }

    @Test func `a snapshot written before the Top Shelf settings still decodes`() throws {
        let json = """
        {"generatedAt":"2026-01-01T00:00:00Z","favorites":[],"onNow":[],
         "continueWatching":[{"id":"movie-1","kind":"movie","title":"A","deepLink":"lume://play/movie/1"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.topShelf == nil)
        #expect(snapshot.continueWatching.first?.backdropURL == nil)
    }

    @Test func `a snapshot naming a section this build doesn't know still decodes`() throws {
        let json = """
        {"generatedAt":"2026-01-01T00:00:00Z","favorites":[],"onNow":[],"continueWatching":[],
         "topShelf":{"isEnabled":true,"style":"sectioned","itemsPerSection":10,
                     "sections":["continueWatching","onNow","favorites"]}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.topShelf?.sections == [.continueWatching, .favorites])
    }
}
