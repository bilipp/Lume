//
//  LiveTVSectionGroupTests.swift
//  LumeTests
//
//  The Live TV rail's grouping: one flat untitled list for a single Live TV
//  playlist, one titled group per contributing member in Combined.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct LiveTVSectionGroupTests {
    private func playlist(_ name: String) -> Playlist {
        Playlist(name: name, serverURL: "http://\(name)", username: "u", password: "p")
    }

    private func category(_ apiId: String, _ name: String, in playlist: Playlist) -> LiveTVSection {
        .category(Lume.Category(apiId: apiId, name: name, parentId: 0, type: .live, playlist: playlist))
    }

    @Test func `isolated rail is one untitled group with the pinned collections first`() {
        let mine = playlist("Mine")
        let sections = [category("1", "News", in: mine), category("2", "Sports", in: mine)]

        let categoryGroups = LiveTVSectionGroup.categoryGroups(
            sections, catalogScope: .isolated(mine.id), playlistNames: [mine.id: mine.name]
        )
        let rail = LiveTVSectionGroup.rail(pinned: [.favorites, .recentlyWatched], categoryGroups: categoryGroups)

        #expect(rail.count == 1)
        #expect(rail[0].title == nil)
        #expect(!rail.hasHeaders)
        #expect(rail.allSections.map(\.id) == ["lume.liveSection.favorites", "lume.liveSection.recentlyWatched"]
            + sections.map(\.id))
    }

    @Test func `combined rail groups categories by member in priority order`() {
        let first = playlist("First")
        let second = playlist("Second")
        let scope = CatalogScope.combined([
            (id: second.id, tabs: [.liveTV, .movies]),
            (id: first.id, tabs: [.liveTV])
        ])
        // Sorted across every member, as the memo hands them over; the
        // grouping must keep each member's relative order.
        let sections = [
            category("1", "Sports", in: first),
            category("1", "Sports", in: second),
            category("2", "News", in: first),
            category("2", "Kids", in: second)
        ]

        let categoryGroups = LiveTVSectionGroup.categoryGroups(
            sections, catalogScope: scope, playlistNames: [first.id: "First", second.id: "Second"]
        )
        let rail = LiveTVSectionGroup.rail(pinned: [.favorites], categoryGroups: categoryGroups)

        #expect(rail.map(\.id) == [nil, second.id, first.id])
        #expect(rail.map(\.title) == [nil, "Second", "First"])
        #expect(rail[0].sections == [.favorites])
        #expect(rail[1].sections.map(\.title) == ["Sports", "Kids"])
        #expect(rail[2].sections.map(\.title) == ["Sports", "News"])
        #expect(rail.hasHeaders)
    }

    @Test func `a single Live TV contributor in combined renders without headers`() {
        let live = playlist("Live")
        let vod = playlist("VOD")
        let scope = CatalogScope.combined([
            (id: vod.id, tabs: [.movies, .series]),
            (id: live.id, tabs: [.liveTV])
        ])
        let sections = [category("1", "News", in: live)]

        let categoryGroups = LiveTVSectionGroup.categoryGroups(
            sections, catalogScope: scope, playlistNames: [live.id: "Live", vod.id: "VOD"]
        )
        let rail = LiveTVSectionGroup.rail(pinned: [.recentlyWatched], categoryGroups: categoryGroups)

        #expect(rail.count == 1)
        #expect(rail[0].id == live.id)
        #expect(!rail.hasHeaders)
        #expect(rail.allSections.map(\.id) == ["lume.liveSection.recentlyWatched"] + sections.map(\.id))
    }

    @Test func `a member without visible categories is dropped`() {
        let first = playlist("First")
        let second = playlist("Second")
        let scope = CatalogScope.combined([
            (id: first.id, tabs: [.liveTV]),
            (id: second.id, tabs: [.liveTV])
        ])

        let categoryGroups = LiveTVSectionGroup.categoryGroups(
            [category("1", "News", in: second)],
            catalogScope: scope,
            playlistNames: [first.id: "First", second.id: "Second"]
        )

        #expect(categoryGroups.map(\.id) == [second.id])
        #expect(categoryGroups.map(\.title) == ["Second"])
    }

    @Test func `no categories and nothing pinned is an empty rail`() {
        let mine = playlist("Mine")
        let categoryGroups = LiveTVSectionGroup.categoryGroups(
            [], catalogScope: .isolated(mine.id), playlistNames: [:]
        )

        #expect(categoryGroups.isEmpty)
        #expect(LiveTVSectionGroup.rail(pinned: [], categoryGroups: categoryGroups).isEmpty)
        #expect(LiveTVSectionGroup.rail(pinned: [.favorites], categoryGroups: categoryGroups).map(\.sections)
            == [[.favorites]])
    }
}
