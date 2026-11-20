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
        #expect(provenance.name(forStreamID: "\(first.uuidString)-live-1") == nil)
    }

    @Test func `live TV with two contributors names each channel's playlist`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.liveTV]),
            (id: second, tabs: [.liveTV, .movies])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forStreamID: "\(first.uuidString)-live-1") == "Alpha")
        #expect(provenance.name(forStreamID: "\(second.uuidString)-live-1") == "Beta")
    }

    @Test func `live TV with one contributor stays unbadged`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.movies, .liveTV]),
            (id: second, tabs: [.movies])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forStreamID: "\(first.uuidString)-live-1") == nil)
    }

    @Test func `movies and series are never badged, even with several contributors`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.movies, .series]),
            (id: second, tabs: [.movies, .series])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forStreamID: "\(first.uuidString)-movie-1") == nil)
        #expect(provenance.name(forStreamID: "\(second.uuidString)-series-1") == nil)
    }

    @Test func `a channel from outside the members is unbadged`() {
        let scope = CatalogScope.combined([
            (id: first, tabs: [.liveTV]),
            (id: second, tabs: [.liveTV])
        ])
        let provenance = PlaylistProvenance(scope: scope, names: names)
        #expect(provenance.name(forStreamID: "\(UUID().uuidString)-live-1") == nil)
    }
}
