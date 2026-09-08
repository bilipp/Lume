//
//  LiveChannelNavigatorTests.swift
//  LumeTests
//
//  Covers in-player live channel resolution — the next/previous channel surfing
//  the tvOS player performs on up/down (`LiveChannelNavigator.adjacentMedia`),
//  including which way a press maps onto the list under each `LiveSurfMode`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveChannelNavigatorTests {
    /// One channel to seed. Only `num` / `name` / `category` matter to the plain
    /// category tests; the flags drive the Favorites / Recently Watched scopes
    /// and the hidden-channel filtering.
    private struct StreamSpec {
        var num: Int
        var name: String
        var category: String
        var isFavorite = false
        var favoriteOrder: Int?
        var isHidden = false
        var lastWatched: Date?
    }

    // Mirrors the id scheme ContentSyncManager writes:
    // "<playlistUUID>-live-<streamId>". The playlist prefix is what
    // `playlist(for:)` keys off, so tests must reproduce it.
    private func makeWorld(streams: [StreamSpec]) throws -> (ModelContext, Playlist) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test",
            serverURL: "http://example.com:8080",
            username: "user",
            password: "pass"
        )
        context.insert(playlist)

        for (offset, spec) in streams.enumerated() {
            let streamId = 100 + offset
            let stream = LiveStream(
                id: "\(playlist.id.uuidString)-live-\(streamId)",
                streamId: streamId,
                name: spec.name,
                num: spec.num,
                categoryId: spec.category
            )
            stream.isFavorite = spec.isFavorite
            stream.favoriteOrder = spec.favoriteOrder
            stream.isHidden = spec.isHidden
            stream.lastWatchedDate = spec.lastWatched
            context.insert(stream)
        }
        try context.save()
        return (context, playlist)
    }

    private func liveRef(_ streamId: Int, _ playlist: Playlist) -> PlayableMedia.ContentRef {
        .live("\(playlist.id.uuidString)-live-\(streamId)")
    }

    private func media(
        forStreamId streamId: Int,
        playlist: Playlist,
        scope: LiveChannelScope? = nil,
        in context: ModelContext
    ) throws -> PlayableMedia {
        let id = "\(playlist.id.uuidString)-live-\(streamId)"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let stream = try #require(try context.fetch(descriptor).first)
        return try #require(PlayableMedia.from(stream: stream, playlist: playlist, scope: scope))
    }

    private let threeChannels: [StreamSpec] = [
        StreamSpec(num: 1, name: "Alpha", category: "cat-a"),
        StreamSpec(num: 2, name: "Bravo", category: "cat-a"),
        StreamSpec(num: 3, name: "Charlie", category: "cat-a")
    ]

    // MARK: - Remote direction

    /// Surfing one press in `direction` under `mode`, from Bravo, the middle of
    /// `threeChannels`. Wraps the argument list the four engine hosts pass so a
    /// direction test reads as the press it stands for.
    private func surf(
        _ direction: LiveChannelNavigator.SurfDirection,
        _ mode: LiveSurfMode,
        from media: PlayableMedia,
        in context: ModelContext
    ) -> PlayableMedia? {
        LiveChannelNavigator.adjacentMedia(
            for: media, surfing: direction, mode: mode,
            sort: .playlist, restriction: ContentRestriction(), in: context
        )
    }

    @Test func `channel up-down maps up to the next channel`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        #expect(surf(.up, .channelUpDown, from: bravo, in: context)?.contentRef == liveRef(102, playlist)) // Charlie
        #expect(surf(.down, .channelUpDown, from: bravo, in: context)?.contentRef == liveRef(100, playlist)) // Alpha
    }

    @Test func `list order maps up to the row above`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        #expect(surf(.up, .listOrder, from: bravo, in: context)?.contentRef == liveRef(100, playlist)) // Alpha
        #expect(surf(.down, .listOrder, from: bravo, in: context)?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test(arguments: LiveSurfMode.allCases)
    func `surfing up then down returns to where it started`(mode: LiveSurfMode) throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let stepped = try #require(surf(.up, mode, from: bravo, in: context))
        #expect(surf(.down, mode, from: stepped, in: context)?.contentRef == bravo.contentRef)
    }

    @Test func `an unset preference surfs the way it always has`() {
        #expect(LiveSurfMode.resolve(nil) == .channelUpDown)
        #expect(LiveSurfMode.resolve("not a mode") == .channelUpDown)
    }

    // MARK: - Next / previous

    @Test func `next channel follows playlist order`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `previous channel follows playlist order`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let previous = LiveChannelNavigator.adjacentMedia(for: bravo, offset: -1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(previous?.contentRef == liveRef(100, playlist)) // Alpha
    }

    // MARK: - Wraparound

    @Test func `next wraps from last to first`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let charlie = try media(forStreamId: 102, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: charlie, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(100, playlist)) // Alpha
    }

    @Test func `previous wraps from first to last`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        let previous = LiveChannelNavigator.adjacentMedia(for: alpha, offset: -1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(previous?.contentRef == liveRef(102, playlist)) // Charlie
    }

    // MARK: - Sort order is honoured

    @Test func `adjacency follows the requested sort`() throws {
        // Playlist order puts Alpha first; name-descending flips it to
        // Charlie, Bravo, Alpha — so Bravo's "next" becomes Alpha.
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .nameDescending, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(100, playlist)) // Alpha
    }

    // MARK: - Scoping

    @Test func `adjacency stays within the same category`() throws {
        // Bravo is the lone channel in cat-b; another category's channels must
        // not leak in, so there is no neighbour to surf to.
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a"),
            StreamSpec(num: 2, name: "Bravo", category: "cat-b"),
            StreamSpec(num: 3, name: "Charlie", category: "cat-a")
        ])
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next == nil)
    }

    @Test func `single channel category has no neighbour`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a")
        ])
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(LiveChannelNavigator.adjacentMedia(for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context) == nil)
        #expect(LiveChannelNavigator.adjacentMedia(for: alpha, offset: -1, sort: .playlist, restriction: ContentRestriction(), in: context) == nil)
    }

    // MARK: - Launch scope

    /// Alpha and Charlie are favorited from different categories; Bravo sits
    /// between them in cat-a but isn't a favorite.
    private let mixedFavorites: [StreamSpec] = [
        StreamSpec(num: 1, name: "Alpha", category: "cat-a", isFavorite: true),
        StreamSpec(num: 2, name: "Bravo", category: "cat-a"),
        StreamSpec(num: 3, name: "Charlie", category: "cat-b", isFavorite: true)
    ]

    @Test func `favorites surfing stays in the favorites list`() throws {
        let (context, playlist) = try makeWorld(streams: mixedFavorites)
        let alpha = try media(forStreamId: 100, playlist: playlist, scope: .favorites, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        // Charlie, the other favorite — not Bravo, Alpha's own category neighbour.
        #expect(next?.contentRef == liveRef(102, playlist))
    }

    @Test func `favorites order follows favoriteOrder`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a", isFavorite: true, favoriteOrder: 2),
            StreamSpec(num: 2, name: "Bravo", category: "cat-a", isFavorite: true, favoriteOrder: 0),
            StreamSpec(num: 3, name: "Charlie", category: "cat-b", isFavorite: true, favoriteOrder: 1)
        ])
        let bravo = try media(forStreamId: 101, playlist: playlist, scope: .favorites, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `the launch scope travels to the next channel`() throws {
        let (context, playlist) = try makeWorld(streams: mixedFavorites)
        let alpha = try media(forStreamId: 100, playlist: playlist, scope: .favorites, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.channelScope == .favorites)
    }

    @Test func `recently watched surfing stays in the recents list`() throws {
        let now = Date()
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a", lastWatched: now),
            StreamSpec(num: 2, name: "Bravo", category: "cat-a"),
            StreamSpec(num: 3, name: "Charlie", category: "cat-b", lastWatched: now.addingTimeInterval(-60))
        ])
        let alpha = try media(forStreamId: 100, playlist: playlist, scope: .recentlyWatched, in: context)

        // Most recent first: Alpha, Charlie — Bravo was never watched.
        let next = LiveChannelNavigator.adjacentMedia(for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `scope falls back to the category when the channel left the list`() throws {
        // Bravo was launched from Favorites and un-favorited since; surfing must
        // keep working from its own category rather than dead-end.
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, scope: .favorites, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    // MARK: - Hidden channels

    @Test func `hidden channels are skipped`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a"),
            StreamSpec(num: 2, name: "Bravo", category: "cat-a", isHidden: true),
            StreamSpec(num: 3, name: "Charlie", category: "cat-a")
        ])
        let alpha = try media(forStreamId: 100, playlist: playlist, scope: .category("cat-a"), in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie, not hidden Bravo
    }

    @Test func `a hidden channel still surfs its category`() throws {
        // A hidden channel can be playing (recall, deep link) even though no
        // browse list contains it — it must not dead-end.
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a"),
            StreamSpec(num: 2, name: "Bravo", category: "cat-a", isHidden: true),
            StreamSpec(num: 3, name: "Charlie", category: "cat-a")
        ])
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    // MARK: - Non-live input

    @Test func `non-live media has no adjacent channel`() throws {
        let (context, _) = try makeWorld(streams: threeChannels)
        let movie = try #require(PlayableMedia.from(
            movie: Movie(id: "m-1", streamId: 1, name: "Film", containerExtension: "mp4"),
            playlist: Playlist(name: "P", serverURL: "http://e.com", username: "u", password: "p")
        ))

        #expect(LiveChannelNavigator.adjacentMedia(for: movie, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context) == nil)
    }

    // MARK: - Hidden channels and parental locks

    /// Hides a channel in Content Management, as the settings screen would.
    private func hide(streamId: Int, playlist: Playlist, in context: ModelContext) throws {
        let id = "\(playlist.id.uuidString)-live-\(streamId)"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        try #require(try context.fetch(descriptor).first).isHidden = true
        try context.save()
    }

    @Test func `a hidden channel is skipped when surfing without a scope`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context) // Bravo
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        // No launch scope, so surfing resolves the playing channel's own
        // category — and Bravo, gone from every channel list, is stepped over
        // rather than tuned to.
        let next = LiveChannelNavigator.adjacentMedia(
            for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
        )
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `hiding all but one channel leaves nothing to surf to`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context)
        try hide(streamId: 102, playlist: playlist, in: context)
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(LiveChannelNavigator.adjacentMedia(
            for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
        ) == nil)
    }

    @Test func `surfing off a hidden channel skips the other hidden ones`() throws {
        // Bravo is playing but hidden, so it has no place in any browse list and
        // surfing falls back to its category. That fallback re-admits Bravo — it
        // needs a position to move off — but not Charlie, which is hidden too.
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context) // Bravo, playing
        try hide(streamId: 102, playlist: playlist, in: context) // Charlie
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
        )
        #expect(next?.contentRef == liveRef(100, playlist)) // Alpha, wrapping past hidden Charlie
    }

    @Test func `a hidden channel in a locked category surfs nowhere`() throws {
        // The category fallback keeps a hidden channel from dead-ending, but it
        // must not become a doorway: a child who somehow landed on one still
        // can't rock into the rest of a locked category.
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["cat-a"])

        #expect(LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: restriction, in: context
        ) == nil)
    }

    @Test func `a child profile cannot surf within a locked category`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["cat-a"])

        #expect(LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: restriction, in: context
        ) == nil)
    }

    @Test func `a parent profile surfs a locked category normally`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        // isActive false — a lock applies only while a child profile is active.
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: ["cat-a"])

        let next = LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: restriction, in: context
        )
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }
}
