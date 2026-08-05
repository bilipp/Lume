import Foundation
@testable import Lume
import Testing

struct HomeLayoutSettingsTests {
    // MARK: - encode / decode

    @Test func `encode single section`() {
        let result = HomeLayoutSettings.encode([.recentlyWatched])
        #expect(result == "recentlyWatched")
    }

    @Test func `encode multiple sections`() {
        let result = HomeLayoutSettings.encode([.favorites, .forYou])
        #expect(result == "favorites,forYou")
    }

    @Test func `decode single section`() {
        let result = HomeLayoutSettings.decode("recentlyWatched")
        #expect(result == [.recentlyWatched])
    }

    @Test func `decode multiple sections`() {
        let result = HomeLayoutSettings.decode("favorites,forYou")
        #expect(result == [.favorites, .forYou])
    }

    @Test func `decode unknown tokens are dropped`() {
        let result = HomeLayoutSettings.decode("favorites,bogus,recentlyWatched")
        #expect(result == [.favorites, .recentlyWatched])
    }

    @Test func `decode empty string`() {
        let result = HomeLayoutSettings.decode("")
        #expect(result.isEmpty)
    }

    @Test func `encode then decode round trip`() {
        let input: [HomeSection] = [.recentlyWatched, .favorites, .forYou, .trendingMovies, .trendingSeries, .traktWatchlist]
        let encoded = HomeLayoutSettings.encode(input)
        let decoded = HomeLayoutSettings.decode(encoded)
        #expect(decoded == input)
    }

    // MARK: - normalized

    @Test func `normalized keeps given order and appends missing`() {
        let result = HomeLayoutSettings.normalized([.forYou, .recentlyWatched])
        #expect(result.first == .forYou)
        #expect(result[1] == .recentlyWatched)
        for section in HomeSection.allCases {
            #expect(result.contains(section))
        }
    }

    @Test func `normalized deduplicates`() {
        let result = HomeLayoutSettings.normalized([.favorites, .favorites, .forYou, .favorites])
        let favoritesCount = result.filter { $0 == .favorites }.count
        #expect(favoritesCount == 1)
    }

    @Test func `normalized empty input falls back to all sections`() {
        let result = HomeLayoutSettings.normalized([])
        #expect(result == HomeSection.allCases)
    }

    @Test func `normalized handles partial list`() {
        let result = HomeLayoutSettings.normalized([.traktWatchlist, .trendingMovies])
        #expect(result.first == .traktWatchlist)
        #expect(result[1] == .trendingMovies)
        #expect(result.count == HomeSection.allCases.count)
    }

    // MARK: - resolve

    @Test func `resolve with stored order uses it`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "favorites,forYou")
        #expect(result.first == .favorites)
        #expect(result[1] == .forYou)
    }

    @Test func `resolve with empty string falls back to all sections`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "")
        #expect(result == HomeSection.allCases)
    }

    // MARK: - encodeDisabled / decodeDisabled

    @Test func `encodeDisabled single section`() {
        let result = HomeLayoutSettings.encodeDisabled([.trendingMovies])
        #expect(result == "trendingMovies")
    }

    @Test func `encodeDisabled multiple sections sorted`() {
        let result = HomeLayoutSettings.encodeDisabled([.forYou, .favorites])
        #expect(result == "favorites,forYou")
    }

    @Test func `decodeDisabled single section`() {
        let result = HomeLayoutSettings.decodeDisabled("favorites")
        #expect(result == [.favorites])
    }

    @Test func `decodeDisabled multiple sections`() {
        let result = HomeLayoutSettings.decodeDisabled("favorites,forYou")
        #expect(result == [.favorites, .forYou])
    }

    @Test func `decodeDisabled empty string`() {
        let result = HomeLayoutSettings.decodeDisabled("")
        #expect(result.isEmpty)
    }

    @Test func `decodeDisabled ignores unknown sections`() {
        let result = HomeLayoutSettings.decodeDisabled("favorites,bogus,forYou")
        #expect(result == [.favorites, .forYou])
    }

    @Test func `encode then decode disabled round trip`() {
        let input: Set<HomeSection> = [.favorites, .trendingMovies, .traktWatchlist]
        let encoded = HomeLayoutSettings.encodeDisabled(input)
        let decoded = HomeLayoutSettings.decodeDisabled(encoded)
        #expect(decoded == input)
    }

    // MARK: - isEnabled

    @Test func `isEnabled returns true for sections not in disabled set`() {
        #expect(HomeLayoutSettings.isEnabled(.recentlyWatched, disabledRaw: ""))
        #expect(HomeLayoutSettings.isEnabled(.recentlyWatched, disabledRaw: "favorites"))
    }

    @Test func `isEnabled returns false for disabled section`() {
        #expect(!HomeLayoutSettings.isEnabled(.favorites, disabledRaw: "favorites,forYou"))
    }

    // MARK: - HomeSection properties

    @Test func `home section all cases are unique`() {
        let ids = HomeSection.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func `home section has non empty system images`() {
        for section in HomeSection.allCases {
            #expect(!section.systemImage.isEmpty)
        }
    }
}
