//
//  LiveChannelQueryTests.swift
//  LumeTests
//
//  Covers the shared scoping helpers every Live TV channel list and category
//  rail funnels through. The parental filter lives here rather than in each
//  view precisely so it can be tested once and cannot be forgotten by a new
//  surface — the tvOS channel list, the in-player browser and the EPG guide all
//  shipped without it while the iOS list had it.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct LiveChannelQueryTests {
    /// Real `LiveStream` / `Category` instances rather than stand-ins — the
    /// helpers read `id`, `categoryId`, `type` and `isHidden` off the models
    /// themselves. No `ModelContainer`: both helpers are pure functions over the
    /// array they're handed, so inserting and saving would only add cost.
    private func stream(_ suffix: String, playlist: UUID, category: String?) -> LiveStream {
        LiveStream(id: "\(playlist.uuidString)-live-\(suffix)", streamId: 1, name: "Ch \(suffix)", categoryId: category)
    }

    // MARK: - scoped

    @Test func `favorites scope drops channels in a locked category`() {
        let pid = UUID()
        let scope = CatalogScope.isolated(pid)
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [
            stream("1", playlist: pid, category: locked),
            stream("2", playlist: pid, category: "\(pid.uuidString)-live-open")
        ]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        let kept = LiveChannelQuery.scoped(streams, scope: .favorites, catalogScope: scope, restriction: restriction)

        // A channel favorited *before* its category was locked is exactly the
        // case the virtual collections leak, since they cut across categories.
        #expect(kept.map(\.name) == ["Ch 2"])
    }

    @Test func `recently watched scope drops channels in a locked category`() {
        let pid = UUID()
        let scope = CatalogScope.isolated(pid)
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [stream("1", playlist: pid, category: locked)]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        let kept = LiveChannelQuery.scoped(streams, scope: .recentlyWatched, catalogScope: scope, restriction: restriction)
        #expect(kept.isEmpty)
    }

    @Test func `a parent profile keeps every channel`() {
        let pid = UUID()
        let scope = CatalogScope.isolated(pid)
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [
            stream("1", playlist: pid, category: locked),
            stream("2", playlist: pid, category: "\(pid.uuidString)-live-open")
        ]
        // isActive false — restriction applies only while a child profile is on.
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: [locked])

        let kept = LiveChannelQuery.scoped(streams, scope: .favorites, catalogScope: scope, restriction: restriction)
        #expect(kept.count == 2)
    }

    @Test func `virtual scopes still isolate the active playlist`() {
        let mine = UUID()
        let other = UUID()
        let streams = [
            stream("1", playlist: mine, category: nil),
            stream("2", playlist: other, category: nil)
        ]

        let kept = LiveChannelQuery.scoped(
            streams, scope: .favorites, catalogScope: .isolated(mine), restriction: ContentRestriction()
        )
        #expect(kept.map(\.name) == ["Ch 1"])
    }

    @Test func `category scope is not playlist-filtered but is still restriction-filtered`() {
        let pid = UUID()
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [
            stream("1", playlist: pid, category: locked),
            stream("2", playlist: pid, category: "\(pid.uuidString)-live-open")
        ]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        // A scope no stream belongs to: category ids are already
        // playlist-prefixed, so the category scope must skip the playlist filter
        // entirely — while a locked category still never renders.
        let kept = LiveChannelQuery.scoped(
            streams, scope: .category(locked), catalogScope: .isolated(UUID()), restriction: restriction
        )
        #expect(kept.map(\.name) == ["Ch 2"])
    }

    // MARK: - visibleCategories

    @Test func `visible categories drop hidden, locked, other playlists and other types`() {
        let playlist = Playlist(name: "Mine", serverURL: "http://x", username: "u", password: "p")
        let scope = CatalogScope.isolated(playlist.id)

        let open = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: playlist)
        let hidden = Lume.Category(apiId: "2", name: "Shopping", parentId: 0, type: .live, playlist: playlist)
        hidden.isHidden = true
        let locked = Lume.Category(apiId: "3", name: "Adults", parentId: 0, type: .live, playlist: playlist)
        // A VOD category of the same playlist shares the prefix, so only the
        // type check keeps it out of a *live* rail.
        let movies = Lume.Category(apiId: "4", name: "Action", parentId: 0, type: .vod, playlist: playlist)

        let otherPlaylist = Playlist(name: "Theirs", serverURL: "http://y", username: "u", password: "p")
        let foreign = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: otherPlaylist)

        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked.id])
        let visible = LiveChannelQuery.visibleCategories(
            [open, hidden, locked, movies, foreign], catalogScope: scope, restriction: restriction
        )

        #expect(visible.map(\.id) == [open.id])
    }

    @Test func `a parent profile still sees a locked category but never a hidden one`() {
        let playlist = Playlist(name: "Mine", serverURL: "http://x", username: "u", password: "p")
        let scope = CatalogScope.isolated(playlist.id)

        let hidden = Lume.Category(apiId: "2", name: "Shopping", parentId: 0, type: .live, playlist: playlist)
        hidden.isHidden = true
        let locked = Lume.Category(apiId: "3", name: "Adults", parentId: 0, type: .live, playlist: playlist)

        // Hiding is a viewer-agnostic Content Management choice; locking only
        // applies to a child profile. The two must not be conflated.
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: [locked.id])
        let visible = LiveChannelQuery.visibleCategories([hidden, locked], catalogScope: scope, restriction: restriction)

        #expect(visible.map(\.id) == [locked.id])
    }

    // MARK: - Combined

    @Test func `combined virtual scopes keep every live member and nothing else`() {
        let first = UUID()
        let second = UUID()
        let moviesOnly = UUID()
        let outsider = UUID()
        let scope = CatalogScope.combined([
            (id: first, tabs: [.liveTV, .movies]),
            (id: second, tabs: [.liveTV]),
            (id: moviesOnly, tabs: [.movies])
        ])
        let streams = [
            stream("1", playlist: first, category: nil),
            stream("2", playlist: second, category: nil),
            stream("3", playlist: moviesOnly, category: nil),
            stream("4", playlist: outsider, category: nil)
        ]

        let kept = LiveChannelQuery.scoped(streams, scope: .favorites, catalogScope: scope, restriction: ContentRestriction())

        // A member that does not contribute Live TV is outside the Live TV scope.
        #expect(kept.map(\.name) == ["Ch 1", "Ch 2"])
        #expect(LiveChannelQuery.containsVisible([streams[2], streams[3]], catalogScope: scope, restriction: ContentRestriction()) == false)
    }

    @Test func `combined visible categories span the live members`() {
        let first = Playlist(name: "First", serverURL: "http://x", username: "u", password: "p")
        let second = Playlist(name: "Second", serverURL: "http://y", username: "u", password: "p")
        let outsider = Playlist(name: "Outsider", serverURL: "http://z", username: "u", password: "p")
        let scope = CatalogScope.combined([(id: first.id, tabs: [.liveTV]), (id: second.id, tabs: [.liveTV])])

        let news = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: first)
        let sport = Lume.Category(apiId: "1", name: "Sport", parentId: 0, type: .live, playlist: second)
        let foreign = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: outsider)

        let visible = LiveChannelQuery.visibleCategories(
            [news, sport, foreign], catalogScope: scope, restriction: ContentRestriction()
        )
        #expect(visible.map(\.id) == [news.id, sport.id])
    }

    @Test func `the empty scope keeps no virtual-collection channel`() {
        let streams = [stream("1", playlist: UUID(), category: nil)]
        let kept = LiveChannelQuery.scoped(streams, scope: .favorites, catalogScope: .empty, restriction: ContentRestriction())
        #expect(kept.isEmpty)
    }

    // MARK: - containsVisible

    @Test func `rail gating agrees with what the list will render`() {
        let pid = UUID()
        let scope = CatalogScope.isolated(pid)
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [stream("1", playlist: pid, category: locked)]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        // The rail must not offer Favorites when every favorite would be
        // filtered out of the list it opens.
        #expect(LiveChannelQuery.containsVisible(streams, catalogScope: scope, restriction: restriction) == false)
        #expect(LiveChannelQuery.containsVisible(streams, catalogScope: scope, restriction: ContentRestriction()))
    }
}
