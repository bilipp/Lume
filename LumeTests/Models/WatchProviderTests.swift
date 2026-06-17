import Foundation
@testable import Lume
import SwiftData
import Testing

struct WatchProviderIDsTests {
    @Test func `encodes ids with sentinels and de-dupes preserving order`() {
        #expect(WatchProviderIDs.encode([8, 337, 8]) == "|8|337|")
    }

    @Test func `encodes an empty list as nil`() {
        #expect(WatchProviderIDs.encode([]) == nil)
    }

    @Test func `decodes a sentinel string back to ids`() {
        #expect(WatchProviderIDs.decode("|8|337|") == [8, 337])
        #expect(WatchProviderIDs.decode(nil) == [])
        #expect(WatchProviderIDs.decode("") == [])
    }

    @Test func `round-trips through encode and decode`() {
        let ids = [8, 337, 9]
        #expect(WatchProviderIDs.decode(WatchProviderIDs.encode(ids)) == ids)
    }

    @Test func `contains matches whole ids only, never substrings`() {
        let raw = WatchProviderIDs.encode([8, 337])
        #expect(WatchProviderIDs.contains(raw, id: 8))
        #expect(WatchProviderIDs.contains(raw, id: 337))
        // 80 / 3 must not match 8 / 337 — the sentinel guards against substring hits.
        #expect(!WatchProviderIDs.contains(raw, id: 80))
        #expect(!WatchProviderIDs.contains(raw, id: 3))
    }

    @Test func `query token wraps the id in sentinels`() {
        #expect(WatchProviderIDs.queryToken(for: 8) == "|8|")
    }
}

@MainActor
struct WatchProviderDerivationTests {
    private let prefix = "11111111-1111-1111-1111-111111111111-"
    private let otherPrefix = "22222222-2222-2222-2222-222222222222-"

    private func makeMovie(streamId: Int, providerIDs: [Int], prefix: String) -> Movie {
        let movie = Movie(id: "\(prefix)movie-\(streamId)", streamId: streamId, name: "Movie \(streamId)")
        movie.watchProviderIds = providerIDs
        return movie
    }

    private func catalog(_ context: ModelContext) {
        context.insert(WatchProvider(id: 8, name: "Netflix", displayPriority: 0))
        context.insert(WatchProvider(id: 337, name: "Disney Plus", displayPriority: 1))
        context.insert(WatchProvider(id: 9, name: "Prime Video", displayPriority: 2))
    }

    @Test func `excludes providers that only appear in a different playlist`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        catalog(context)
        context.insert(makeMovie(streamId: 1, providerIDs: [8], prefix: prefix))
        context.insert(makeMovie(streamId: 2, providerIDs: [9], prefix: prefix))
        // Disney (337) appears only in the other playlist's title.
        context.insert(makeMovie(streamId: 3, providerIDs: [337], prefix: otherPrefix))

        // User subscribes to Netflix (8) and Disney (337) but not Prime (9).
        let result = WatchProviderDerivation.movieProviders(
            in: context,
            playlistPrefix: prefix,
            restriction: ContentRestriction(),
            selected: [8, 337]
        )
        // 337 is only in the other playlist, so only Netflix survives here.
        #expect(result.map(\.id) == [8])
    }

    @Test func `returns selected providers present in the playlist in priority order`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        catalog(context)
        context.insert(makeMovie(streamId: 1, providerIDs: [337, 8], prefix: prefix))

        let result = WatchProviderDerivation.movieProviders(
            in: context,
            playlistPrefix: prefix,
            restriction: ContentRestriction(),
            selected: [8, 337]
        )
        // Both present and selected — ordered by catalog display priority (8 before 337).
        #expect(result.map(\.id) == [8, 337])
    }

    @Test func `intersects present and selected, dropping unselected providers`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        catalog(context)
        context.insert(makeMovie(streamId: 1, providerIDs: [8, 9], prefix: prefix))

        let result = WatchProviderDerivation.movieProviders(
            in: context,
            playlistPrefix: prefix,
            restriction: ContentRestriction(),
            selected: [8] // Prime (9) is present but not selected.
        )
        #expect(result.map(\.id) == [8])
    }

    @Test func `is empty when nothing is selected`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        catalog(context)
        context.insert(makeMovie(streamId: 1, providerIDs: [8], prefix: prefix))

        #expect(WatchProviderDerivation.movieProviders(
            in: context,
            playlistPrefix: prefix,
            restriction: ContentRestriction(),
            selected: []
        ).isEmpty)
    }
}
