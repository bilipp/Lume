import Foundation
@testable import Lume
import Testing

struct PlaylistProvenanceTests {
    private let first = UUID()
    private let second = UUID()

    private var names: [UUID: String] {
        [first: "Alpha", second: "Beta"]
    }

    @Test func `isolated mode never badges`() {
        let provenance = PlaylistProvenance(scope: .isolated(first), names: names)
        #expect(provenance.name(forContentID: "\(first.uuidString)-movie-1", in: .movies) == nil)
    }

    @Test func `a tab with two contributors names each row's playlist`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.movies, .liveTV]),
            (id: second, tabs: [.movies])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forContentID: "\(first.uuidString)-movie-1", in: .movies) == "Alpha")
        #expect(provenance.name(forContentID: "\(second.uuidString)-movie-1", in: .movies) == "Beta")
    }

    @Test func `a tab with one contributor stays unbadged`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.movies, .liveTV]),
            (id: second, tabs: [.movies])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forContentID: "\(first.uuidString)-live-1", in: .liveTV) == nil)
        #expect(provenance.name(forContentID: "\(first.uuidString)-series-1", in: .series) == nil)
    }

    @Test func `a row from outside the members is unbadged`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.series]),
            (id: second, tabs: [.series])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forContentID: "\(UUID().uuidString)-series-1", in: .series) == nil)
    }
}
