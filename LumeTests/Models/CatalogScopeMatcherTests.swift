//
//  CatalogScopeMatcherTests.swift
//  LumeTests
//
//  Home's in-memory scoping of already-fetched rows and its Favorites order.
//

import Foundation
@testable import Lume
import Testing

struct CatalogScopeMatcherTests {
    private let first = UUID()
    private let second = UUID()

    private func id(_ playlist: UUID, _ suffix: String) -> String {
        "\(playlist.uuidString)-\(suffix)"
    }

    @Test func `an isolated scope keeps every type of its own playlist only`() {
        let matcher = CatalogScope.Matcher(.isolated(first))
        for tab in PlaylistTab.allCases {
            #expect(matcher.contains(id(first, "1"), tab))
            #expect(!matcher.contains(id(second, "1"), tab))
        }
        #expect(matcher.memberRank(of: id(first, "1")) == 0)
    }

    @Test func `the empty scope filters nothing`() {
        let matcher = CatalogScope.Matcher(.empty)
        #expect(matcher.contains(id(first, "1"), .movies))
        #expect(matcher.memberRank(of: id(first, "1")) == .max)
    }

    @Test func `a combined scope keeps only the types each member contributes`() {
        let scope = CatalogScope.combined([(id: second, tabs: [.movies]), (id: first, tabs: [.liveTV, .movies])])
        let matcher = CatalogScope.Matcher(scope)
        #expect(matcher.contains(id(second, "m"), .movies))
        #expect(!matcher.contains(id(second, "c"), .liveTV))
        #expect(matcher.contains(id(first, "c"), .liveTV))
        #expect(!matcher.contains(id(first, "s"), .series))
        #expect(matcher.memberRank(of: id(second, "m")) == 0)
        #expect(matcher.memberRank(of: id(first, "m")) == 1)
        #expect(matcher.memberRank(of: "\(UUID().uuidString)-x") == .max)
    }

    @MainActor
    @Test func `the memo rebuilds only when the scope changes`() {
        let memo = CatalogScopeMatcherMemo()
        let isolated = memo.matcher(for: .isolated(first))
        #expect(memo.matcher(for: .isolated(first)) == isolated)
        let switched = memo.matcher(for: .isolated(second))
        #expect(switched.scope == .isolated(second))
        #expect(switched.contains(id(second, "1"), .movies))
    }

    @Test func `favorites follow the manual order, then member priority, type, number and name`() {
        typealias Entry = FavoritesOrder.Entry<String>
        let sorted = FavoritesOrder.sorted([
            Entry(order: nil, member: 1, kind: 0, num: 1, name: "B channel", item: "member2-channel"),
            Entry(order: nil, member: 0, kind: 1, num: 1, name: "Z movie", item: "member1-movie"),
            Entry(order: nil, member: 0, kind: 0, num: 1, name: "Y channel", item: "member1-channel"),
            Entry(order: 0, member: 1, kind: 2, num: 9, name: "A series", item: "ordered"),
            Entry(order: nil, member: 0, kind: 0, num: 1, name: "A channel", item: "member1-channel-a"),
            Entry(order: nil, member: 0, kind: 0, num: 0, name: "Z channel", item: "member1-channel-first")
        ])
        #expect(sorted == ["ordered", "member1-channel-first", "member1-channel-a", "member1-channel", "member1-movie", "member2-channel"])
    }
}
