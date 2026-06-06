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
