//
//  CatalogScopeSelectionTests.swift
//  LumeTests
//
//  The browse surfaces' reads of the resolved selection: which switcher row is
//  current, the one playlist a single-playlist read gets, the switcher title,
//  and Search's per-type member scoping in Combined.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CatalogScopeSelectionTests {
    private func makePlaylists(_ names: [String], in context: ModelContext) throws -> [Playlist] {
        let playlists = names.map { Playlist(name: $0, serverURL: "http://\($0)", username: "u", password: "p") }
        for (offset, playlist) in playlists.enumerated() {
            playlist.addedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
            context.insert(playlist)
        }
        try context.save()
        return playlists
    }

    /// Second (priority 1) contributes Movies, First (priority 2) Live TV.
    private func makeCombined(_ playlists: [Playlist]) {
        playlists[1].combinedTabs = [.movies]
        playlists[1].combinedPriority = 1
        playlists[0].combinedTabs = [.liveTV]
        playlists[0].combinedPriority = 2
    }

    // MARK: - Rows

    @Test func `an isolated scope marks its playlist current`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        let scope = playlists.scope(for: playlists[1].id.uuidString, isPremium: true)

        let rows = QuickSwitchResolver.playlistRows(playlists, scope: scope)

        #expect(rows.map(\.isCurrent) == [false, true])
    }

    @Test func `combined marks no playlist current and never the oldest`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        makeCombined(playlists)
        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        let rows = QuickSwitchResolver.playlistRows(playlists, scope: scope)

        #expect(rows.allSatisfy { !$0.isCurrent })
    }

    @Test func `a lapsed combined selection marks the priority-1 member current`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        makeCombined(playlists)
        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: false)

        let rows = QuickSwitchResolver.playlistRows(playlists, scope: scope)

        #expect(rows.map(\.isCurrent) == [false, true])
    }

    // MARK: - Single-playlist reads

    @Test func `the primary member is the priority-1 playlist`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        makeCombined(playlists)
        let scope = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)

        #expect(playlists.primaryMember(of: scope)?.id == playlists[1].id)
        #expect(playlists.members(of: scope, for: .liveTV).map(\.id) == [playlists[0].id])
        #expect(playlists.members(of: scope, for: .series).isEmpty)
        #expect(playlists.primaryMember(of: .empty) == nil)
    }

    @Test func `the switcher title names Combined only while it is in effect`() throws {
        let container = try makeProfileTestContainer()
        let playlists = try makePlaylists(["First", "Second"], in: container.mainContext)
        makeCombined(playlists)

        let combined = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: true)
        let lapsed = playlists.scope(for: PlaylistSelectionStore.combined, isPremium: false)

        #expect(!playlists.selectionTitle(for: combined).isEmpty)
        #expect(!playlists.map(\.name).contains(playlists.selectionTitle(for: combined)))
        #expect(playlists.selectionTitle(for: lapsed) == "Second")
        #expect(playlists.selectionTitle(for: .empty).isEmpty)
    }

    // MARK: - Search

    /// On disk: an in-memory store never generates the SQL the predicates run.
    private func makeSQLiteContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func `combined search asks each member only for the types it contributes`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let movieMember = UUID().uuidString
        let liveMember = UUID().uuidString
        context.insert(Movie(id: "\(movieMember)-movie-1", streamId: 1, name: "Matrix A"))
        context.insert(Movie(id: "\(liveMember)-movie-2", streamId: 2, name: "Matrix B"))
        try context.save()

        let request = SearchRequest(
            query: "matrix",
            playlistIDs: [movieMember, liveMember],
            wantMovies: true,
            wantSeries: true,
            wantLive: false,
            excludedCategoryIDs: [],
            limit: 10,
            playlistIDsByTab: [.movies: [movieMember], .series: [], .liveTV: [liveMember]]
        )
        let hits = SearchFetcher.fetch(container: container, request: request)

        let names = hits.movies.compactMap { (context.model(for: $0) as? Movie)?.name }
        #expect(names == ["Matrix A"])
        #expect(hits.series.isEmpty)
        #expect(request.scopes(for: .series).isEmpty)
    }

    @Test func `an isolated search request keeps one scope for every type`() {
        let id = UUID().uuidString
        let request = SearchRequest(
            query: "matrix", playlistIDs: [id],
            wantMovies: true, wantSeries: true, wantLive: true,
            excludedCategoryIDs: [], limit: 10
        )

        for tab in PlaylistTab.allCases {
            #expect(request.scopes(for: tab).map(\.playlistID) == [id])
        }
    }
}
