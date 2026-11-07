//
//  LibraryCategoryLayoutTests.swift
//  LumeTests
//
//  Movies/Series category layout: preview rows are the first few categories
//  overall in member priority order; the tile grid is grouped by member and
//  titled only when two or more members contribute the type.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct LibraryCategoryLayoutTests {
    private func playlist(_ name: String) -> Playlist {
        Playlist(name: name, serverURL: "http://\(name)", username: "u", password: "p")
    }

    private func category(_ apiId: String, _ name: String, order: Int, in playlist: Playlist) -> Lume.Category {
        let category = Lume.Category(apiId: apiId, name: name, parentId: 0, type: .vod, playlist: playlist)
        category.sortOrder = order
        return category
    }

    private func layout(
        _ categories: [Lume.Category],
        scope: CatalogScope,
        names: [UUID: String] = [:],
        restriction: ContentRestriction = ContentRestriction(),
        previewLimit: Int = 2
    ) -> LibraryCategoryLayout {
        LibraryCategoryLayout.make(
            categories: categories,
            members: scope.members(for: .movies).map { (id: $0, name: names[$0] ?? "") },
            sort: .playlist,
            restriction: restriction,
            previewLimit: previewLimit
        )
    }

    @Test func `isolated layout is today's preview and one untitled grid`() {
        let mine = playlist("Mine")
        let other = playlist("Other")
        let categories = [
            category("3", "C", order: 3, in: mine),
            category("1", "A", order: 1, in: mine),
            category("9", "Foreign", order: 0, in: other),
            category("2", "B", order: 2, in: mine)
        ]

        let result = layout(categories, scope: .isolated(mine.id), names: [mine.id: "Mine"])

        #expect(result.previews.map(\.name) == ["A", "B"])
        #expect(result.remaining.count == 1)
        #expect(result.remaining[0].title == nil)
        #expect(result.remaining[0].categories.map(\.name) == ["C"])
    }

    @Test func `combined groups by member in priority order with titles`() {
        let first = playlist("First")
        let second = playlist("Second")
        let scope = CatalogScope.combined([
            (id: second.id, tabs: [.movies]),
            (id: first.id, tabs: [.movies, .liveTV])
        ])
        let categories = [
            category("1", "Action", order: 0, in: first),
            category("2", "Drama", order: 1, in: first),
            category("1", "Action", order: 0, in: second),
            category("2", "Comedy", order: 1, in: second),
            category("3", "Kids", order: 2, in: second)
        ]

        let result = layout(categories, scope: scope, names: [first.id: "First", second.id: "Second"])

        #expect(result.previews.map(\.id) == [categories[2].id, categories[3].id])
        #expect(result.remaining.map(\.id) == [second.id, first.id])
        #expect(result.remaining.map(\.title) == ["Second", "First"])
        #expect(result.remaining[0].categories.map(\.name) == ["Kids"])
        #expect(result.remaining[1].categories.map(\.name) == ["Action", "Drama"])
    }

    @Test func `previews span members and a member fully previewed has no grid group`() {
        let first = playlist("First")
        let second = playlist("Second")
        let scope = CatalogScope.combined([
            (id: first.id, tabs: [.movies]),
            (id: second.id, tabs: [.movies])
        ])
        let categories = [
            category("1", "Action", order: 0, in: first),
            category("1", "News", order: 0, in: second),
            category("2", "Sport", order: 1, in: second)
        ]

        let result = layout(categories, scope: scope, names: [first.id: "First", second.id: "Second"])

        #expect(result.previews.map(\.name) == ["Action", "News"])
        #expect(result.remaining.map(\.id) == [second.id])
        #expect(result.remaining[0].categories.map(\.name) == ["Sport"])
    }

    @Test func `only one movie contributor renders without headers`() {
        let live = playlist("Live")
        let vod = playlist("VOD")
        let scope = CatalogScope.combined([
            (id: live.id, tabs: [.liveTV]),
            (id: vod.id, tabs: [.movies, .series])
        ])
        let categories = [
            category("1", "Ignored", order: 0, in: live),
            category("1", "A", order: 0, in: vod),
            category("2", "B", order: 1, in: vod),
            category("3", "C", order: 2, in: vod)
        ]

        let result = layout(categories, scope: scope, names: [live.id: "Live", vod.id: "VOD"])

        #expect(result.previews.map(\.name) == ["A", "B"])
        #expect(result.remaining.map(\.title) == [nil])
        #expect(result.remaining[0].categories.map(\.name) == ["C"])
    }

    @Test func `hidden categories are dropped and an empty scope lays out nothing`() {
        let mine = playlist("Mine")
        let hidden = category("1", "Hidden", order: 0, in: mine)
        let shown = category("2", "Shown", order: 1, in: mine)
        let restriction = ContentRestriction(hiddenCategoryIDs: [hidden.id])

        let result = layout([hidden, shown], scope: .isolated(mine.id), restriction: restriction)
        #expect(result.previews.map(\.name) == ["Shown"])
        #expect(result.remaining.isEmpty)

        #expect(layout([hidden, shown], scope: .empty).isEmpty)
    }
}
