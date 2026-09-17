import Foundation
@testable import Lume
import Testing

struct ContentOrganizerTests {
    // MARK: - Reorder

    @Test func `reorder stamps dense custom order in new arrangement`() {
        let cats = makeCategories(["A", "B", "C", "D"])
        // Move the first item ("A") to the end, mirroring SwiftUI's onMove.
        ContentOrganizer.reorder(cats, from: IndexSet(integer: 0), to: 4)

        // cats is the original array; customOrder reflects the new positions.
        #expect(cats[0].customOrder == 3) // A is now last
        #expect(cats[1].customOrder == 0) // B is now first
        #expect(cats[2].customOrder == 1)
        #expect(cats[3].customOrder == 2)
    }

    @Test func `reordering then playlist-sorting yields the user order`() {
        let cats = makeCategories(["A", "B", "C"])
        // Move "C" (index 2) to the front.
        ContentOrganizer.reorder(cats, from: IndexSet(integer: 2), to: 0)

        let sorted = CategorySortOption.playlist.sort(cats)
        #expect(sorted.map(\.name) == ["C", "A", "B"])
    }

    // MARK: - Commit order (tvOS pick-up/place)

    @Test func `commit order stamps dense custom order from the arrangement`() {
        let cats = makeCategories(["A", "B", "C"])
        // The tvOS reorder hands back a locally-arranged copy on drop; here the
        // user lifted "C" and placed it at the front.
        let arranged = [cats[2], cats[0], cats[1]]
        ContentOrganizer.commitOrder(arranged)

        #expect(cats[0].customOrder == 1) // A
        #expect(cats[1].customOrder == 2) // B
        #expect(cats[2].customOrder == 0) // C is now first

        let sorted = CategorySortOption.playlist.sort(cats)
        #expect(sorted.map(\.name) == ["C", "A", "B"])
    }

    // MARK: - Reset

    @Test func `reset order clears custom order`() {
        let cats = makeCategories(["A", "B", "C"])
        ContentOrganizer.reorder(cats, from: IndexSet(integer: 2), to: 0)
        #expect(cats.contains { $0.customOrder != nil })

        ContentOrganizer.resetOrder(cats)
        #expect(cats.allSatisfy { $0.customOrder == nil })
    }

    @Test func `show all clears hidden flag`() {
        let cats = makeCategories(["A", "B"])
        cats[0].isHidden = true
        cats[1].isHidden = true

        ContentOrganizer.showAll(cats)
        #expect(cats.allSatisfy { !$0.isHidden })
    }

    // MARK: - Bulk hide / show

    @Test func `hide all sets the hidden flag on every item`() {
        let cats = makeCategories(["A", "B", "C"])
        cats[1].isHidden = true // already hidden — stays hidden

        ContentOrganizer.hideAll(cats)
        // Bound outside #expect: SwiftFormat rewrites the closure to a key path,
        // which the macro can't type-check inline.
        let allHidden = cats.allSatisfy(\.isHidden)
        #expect(allHidden)
    }

    @Test func `hide all leaves the custom order untouched`() {
        let cats = makeCategories(["A", "B", "C"])
        ContentOrganizer.reorder(cats, from: IndexSet(integer: 2), to: 0)

        ContentOrganizer.hideAll(cats)
        // Hiding is not Reset: the user's arrangement survives.
        #expect(CategorySortOption.playlist.sort(cats).map(\.name) == ["C", "A", "B"])
    }

    @Test func `hide all then show all on a subset opts that subset back in`() {
        let cats = makeCategories(["UK One", "DE Eins", "UK Two"])
        ContentOrganizer.hideAll(cats)

        // The "hide everything, search UK, show the matches" prune.
        let matches = cats.filter { $0.name.localizedCaseInsensitiveContains("UK") }
        ContentOrganizer.showAll(matches)

        #expect(cats.filter { !$0.isHidden }.map(\.name) == ["UK One", "UK Two"])
    }

    @Test func `hide all applies to live streams too`() {
        let streams = [
            LiveStream(id: "l-1", streamId: 1, name: "First", num: 1),
            LiveStream(id: "l-2", streamId: 2, name: "Second", num: 2)
        ]
        ContentOrganizer.hideAll(streams)
        let allHidden = streams.allSatisfy(\.isHidden)
        #expect(allHidden)

        ContentOrganizer.showAll(streams)
        #expect(streams.allSatisfy { !$0.isHidden })
    }

    // MARK: - LiveStream custom order precedence

    @Test func `live stream custom order overrides provider order`() {
        let streams = [
            LiveStream(id: "l-1", streamId: 1, name: "First", num: 1),
            LiveStream(id: "l-2", streamId: 2, name: "Second", num: 2)
        ]
        // Provider order would be First, Second; reverse it via customOrder.
        ContentOrganizer.reorder(streams, from: IndexSet(integer: 1), to: 0)

        let sorted = streams.sorted(using: ContentSortOption.playlist.liveStreamDescriptors)
        #expect(sorted.map(\.name) == ["Second", "First"])
    }

    @Test func `live stream playlist sort falls back to num without custom order`() {
        let streams = [
            LiveStream(id: "l-1", streamId: 1, name: "B", num: 2),
            LiveStream(id: "l-2", streamId: 2, name: "A", num: 1)
        ]
        let sorted = streams.sorted(using: ContentSortOption.playlist.liveStreamDescriptors)
        #expect(sorted.map(\.name) == ["A", "B"]) // num 1 before num 2
    }

    // MARK: - Cross-type favorites ordering

    @Test func `reorder favorites stamps a dense order spanning types`() {
        let channel = LiveStream(id: "p-live-1", streamId: 1, name: "Channel", num: 1)
        let movie = Movie(id: "p-movie-1", streamId: 2, name: "Movie", num: 1)
        let series = Series(id: "p-series-1", seriesId: 3, name: "Series", num: 1)
        let favorites: [any FavoriteOrderable] = [channel, movie, series]

        // Move the movie (index 1) to the front — above the channel.
        ContentOrganizer.reorderFavorites(favorites, from: IndexSet(integer: 1), to: 0)

        #expect(movie.favoriteOrder == 0) // a movie can sit above a channel
        #expect(channel.favoriteOrder == 1)
        #expect(series.favoriteOrder == 2)
    }

    @Test func `commit favorites order interleaves the types in the given arrangement`() {
        let channel = LiveStream(id: "p-live-1", streamId: 1, name: "Channel", num: 1)
        let movie = Movie(id: "p-movie-1", streamId: 2, name: "Movie", num: 1)
        let series = Series(id: "p-series-1", seriesId: 3, name: "Series", num: 1)

        // The user placed the movie first, then the channel, then the series.
        ContentOrganizer.commitFavoriteOrder([movie, channel, series])

        #expect(movie.favoriteOrder == 0)
        #expect(channel.favoriteOrder == 1)
        #expect(series.favoriteOrder == 2)
    }

    @Test func `reset favorites order clears every type`() {
        let channel = LiveStream(id: "p-live-1", streamId: 1, name: "Channel", num: 1)
        let movie = Movie(id: "p-movie-1", streamId: 2, name: "Movie", num: 1)
        let series = Series(id: "p-series-1", seriesId: 3, name: "Series", num: 1)
        let favorites: [any FavoriteOrderable] = [channel, movie, series]

        ContentOrganizer.commitFavoriteOrder(favorites)
        #expect(favorites.allSatisfy { $0.favoriteOrder != nil })

        ContentOrganizer.resetFavoriteOrder(favorites)
        #expect(favorites.allSatisfy { $0.favoriteOrder == nil })
    }

    // MARK: - Helpers

    private func makeCategories(_ names: [String]) -> [Lume.Category] {
        let playlist = Playlist(name: "P", serverURL: "http://x.com", username: "u", password: "p")
        return names.enumerated().map { index, name in
            let cat = Lume.Category(apiId: "\(index)", name: name, parentId: 0, type: .live, playlist: playlist)
            cat.sortOrder = index
            return cat
        }
    }
}
