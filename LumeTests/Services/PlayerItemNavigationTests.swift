//
//  PlayerItemNavigationTests.swift
//  LumeTests
//
//  Covers the resolution behind the in-player previous/next transport buttons
//  (`PlayerItemNavigation.neighbours`): that a button always means one position
//  along the list whatever the remote's `LiveSurfMode` is, that hidden and
//  parentally locked channels stay out of reach, that the launch scope is
//  honoured, that catch-up recordings offer no channels to surf, and that a
//  series whose episodes haven't been fetched yet reports "unknown" rather than
//  "no neighbour" — and that the three button states the overlays render from
//  (enabled, disabled-but-present, hidden) stay distinct.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct PlayerItemNavigationTests {
    /// One channel to seed. Mirrors `LiveChannelNavigatorTests`' fixture: `num`
    /// / `name` / `category` drive the plain category cases, the flags the
    /// Favorites scope and the hidden-channel filtering.
    private struct StreamSpec {
        var num: Int
        var name: String
        var category: String
        var isFavorite = false
        var isHidden = false
    }

    /// Ids follow the scheme ContentSyncManager writes —
    /// "<playlistUUID>-live-<streamId>" — which is what the playlist prefix match
    /// keys off.
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
            stream.isHidden = spec.isHidden
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

    private func neighbours(
        for media: PlayableMedia,
        restriction: ContentRestriction = ContentRestriction(),
        in context: ModelContext
    ) -> PlayerItemNavigation.Neighbours {
        PlayerItemNavigation.neighbours(
            for: media, sort: .playlist, restriction: restriction, in: context
        )
    }

    private let threeChannels: [StreamSpec] = [
        StreamSpec(num: 1, name: "Alpha", category: "cat-a"),
        StreamSpec(num: 2, name: "Bravo", category: "cat-a"),
        StreamSpec(num: 3, name: "Charlie", category: "cat-a")
    ]

    // MARK: - Channels: the button path is mode-independent

    @Test(arguments: LiveSurfMode.allCases)
    func `the next button is the row below whatever the surf mode is`(mode: LiveSurfMode) throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let resolved = neighbours(for: bravo, in: context)
        #expect(resolved.axis == .channel)
        #expect(resolved.next?.contentRef == liveRef(102, playlist)) // Charlie
        #expect(resolved.previous?.contentRef == liveRef(100, playlist)) // Alpha
        #expect(!resolved.neighboursUnknown)

        // Same list, same sort, but read through the remote's direction mapping:
        // under `.listOrder` an up press walks the other way. A labelled button
        // must not inherit that, so it always matches the raw +1 offset.
        let surfedUp = LiveChannelNavigator.adjacentMedia(
            for: bravo, surfing: .up, mode: mode, sort: .playlist,
            restriction: ContentRestriction(), in: context
        )
        let expectedUp = mode == .channelUpDown ? resolved.next : resolved.previous
        #expect(surfedUp?.contentRef == expectedUp?.contentRef)
    }

    @Test func `the ends of a channel list wrap`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(neighbours(for: alpha, in: context).previous?.contentRef == liveRef(102, playlist))
    }

    @Test func `a lone channel has no neighbours`() throws {
        let (context, playlist) = try makeWorld(streams: [StreamSpec(num: 1, name: "Alpha", category: "cat-a")])
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        let resolved = neighbours(for: alpha, in: context)
        #expect(resolved.axis == .channel)
        #expect(resolved.next == nil)
        #expect(resolved.previous == nil)
        #expect(!resolved.neighboursUnknown)
    }

    // MARK: - Channels: hidden and locked stay out of reach

    @Test func `hidden channels are skipped`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a"),
            StreamSpec(num: 2, name: "Bravo", category: "cat-a", isHidden: true),
            StreamSpec(num: 3, name: "Charlie", category: "cat-a")
        ])
        let alpha = try media(forStreamId: 100, playlist: playlist, scope: .category("cat-a"), in: context)

        #expect(neighbours(for: alpha, in: context).next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `a child profile cannot step into a locked category`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["cat-a"])

        let resolved = neighbours(for: bravo, restriction: restriction, in: context)
        #expect(resolved.next == nil)
        #expect(resolved.previous == nil)
    }

    // MARK: - Channels: the launch scope is honoured

    @Test func `the launch scope decides the list and travels with the swap`() throws {
        // Alpha and Charlie are favorited from different categories; Bravo sits
        // between them in cat-a but isn't a favorite, so Favorites skips it.
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(num: 1, name: "Alpha", category: "cat-a", isFavorite: true),
            StreamSpec(num: 2, name: "Bravo", category: "cat-a"),
            StreamSpec(num: 3, name: "Charlie", category: "cat-b", isFavorite: true)
        ])
        let alpha = try media(forStreamId: 100, playlist: playlist, scope: .favorites, in: context)

        let resolved = neighbours(for: alpha, in: context)
        #expect(resolved.next?.contentRef == liveRef(102, playlist)) // Charlie, not Bravo
        #expect(resolved.next?.channelScope == .favorites)
    }

    // MARK: - Catch-up

    @Test func `catch-up playback offers no channels to surf`() throws {
        // A catch-up recording is on-demand video that still points at the live
        // channel it was recorded from; surfing would drop the viewer out of it.
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let live = try media(forStreamId: 101, playlist: playlist, in: context)
        let catchUp = PlayableMedia(
            id: "catchup-\(live.id)",
            url: live.url,
            title: live.title,
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: live.contentRef,
            channelScope: live.channelScope
        )

        let resolved = neighbours(for: catchUp, in: context)
        #expect(resolved.axis == nil)
        #expect(resolved.next == nil)
        #expect(resolved.previous == nil)
        #expect(!resolved.neighboursUnknown)
    }

    // MARK: - Episodes

    /// A series with the playlist-UUID id prefix and the given `(season,
    /// episode)` pairs, inserted shuffled so the ordering under test is the
    /// resolver's own.
    private func makeSeriesWorld(
        episodes specs: [(season: Int, episode: Int)]
    ) throws -> (ModelContext, Playlist) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test",
            serverURL: "http://example.com:8080",
            username: "user",
            password: "pass"
        )
        context.insert(playlist)
        let series = Series(id: "\(playlist.id.uuidString)-series-1", seriesId: 1, name: "Show")
        context.insert(series)

        for spec in specs {
            let episode = Episode(
                id: episodeID(season: spec.season, episode: spec.episode),
                episodeId: "\(spec.season)\(spec.episode)",
                title: "S\(spec.season)E\(spec.episode)",
                containerExtension: "mkv",
                seasonNum: spec.season,
                episodeNum: spec.episode,
                series: series
            )
            context.insert(episode)
            series.episodes.append(episode)
        }
        try context.save()
        return (context, playlist)
    }

    private func episodeID(season: Int, episode: Int) -> String {
        "ep-s\(season)e\(episode)"
    }

    private func episodeMedia(season: Int, episode: Int) -> PlayableMedia {
        PlayableMedia(
            id: "episode-\(episodeID(season: season, episode: episode))",
            url: URL(string: "http://example.com/series/s\(season)e\(episode).mkv")!,
            title: "S\(season)E\(episode)",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .episode(episodeID(season: season, episode: episode))
        )
    }

    private let twoSeasons: [(season: Int, episode: Int)] = [
        (season: 2, episode: 1),
        (season: 1, episode: 2),
        (season: 1, episode: 1),
        (season: 2, episode: 2)
    ]

    @Test func `episode neighbours cross the season boundary both ways`() throws {
        let (context, _) = try makeSeriesWorld(episodes: twoSeasons)
        let finale = neighbours(for: episodeMedia(season: 1, episode: 2), in: context)
        #expect(finale.axis == .episode)
        #expect(finale.next?.contentRef == .episode(episodeID(season: 2, episode: 1)))
        #expect(finale.previous?.contentRef == .episode(episodeID(season: 1, episode: 1)))
        #expect(!finale.neighboursUnknown)
    }

    @Test func `the series premiere has no previous episode`() throws {
        let (context, _) = try makeSeriesWorld(episodes: twoSeasons)
        let premiere = neighbours(for: episodeMedia(season: 1, episode: 1), in: context)
        #expect(premiere.previous == nil)
        #expect(premiere.next != nil)
        #expect(!premiere.neighboursUnknown)
    }

    @Test func `a series with no episode rows yet reports unknown, not absent`() throws {
        // An Xtream or Stalker series carries no episodes until a detail screen
        // fetches them, so a stream launched from Continue Watching or a deep
        // link can have neighbours the catalog doesn't know about. The buttons
        // must render disabled rather than disappear.
        let (context, _) = try makeSeriesWorld(episodes: [])
        let resolved = neighbours(for: episodeMedia(season: 1, episode: 1), in: context)

        #expect(resolved.axis == .episode)
        #expect(resolved.neighboursUnknown)
        #expect(resolved.next == nil)
        #expect(resolved.previous == nil)
    }

    // MARK: - Movies

    @Test func `a movie has no transport neighbours at all`() throws {
        let (context, _) = try makeSeriesWorld(episodes: twoSeasons)
        let movie = try PlayableMedia(
            id: "movie-m-1",
            url: #require(URL(string: "http://example.com/movie/m-1.mp4")),
            title: "Film",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("m-1")
        )

        let resolved = neighbours(for: movie, in: context)
        #expect(resolved.axis == nil)
        #expect(resolved.next == nil)
        #expect(resolved.previous == nil)
        #expect(!resolved.neighboursUnknown)
    }

    // MARK: - Lock-screen availability

    /// `axis(for:)` is what enables or greys out next/previous track on the
    /// lock screen, and it answers from the stream alone — no catalog, so a
    /// remote command never pays for a fetch just to decide whether to appear.
    @Test func `the lock screen offers navigation only where there is an axis`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let live = try media(forStreamId: 101, playlist: playlist, in: context)
        #expect(PlayerItemNavigation.axis(for: live) == .channel)
        #expect(PlayerItemNavigation.axis(for: episodeMedia(season: 1, episode: 1)) == .episode)

        let catchUp = PlayableMedia(
            id: "catchup-\(live.id)",
            url: live.url,
            title: live.title,
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: live.contentRef
        )
        #expect(PlayerItemNavigation.axis(for: catchUp) == nil)

        let movie = try PlayableMedia(
            id: "movie-m-2",
            url: #require(URL(string: "http://example.com/movie/m-2.mp4")),
            title: "Film",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("m-2")
        )
        #expect(PlayerItemNavigation.axis(for: movie) == nil)
    }

    // MARK: - Button state

    /// The three states the transport buttons must keep apart. `.disabled` and
    /// `.hidden` are different answers on purpose: a stale catalog keeps the
    /// button in place, a movie never had one.
    @Test func `a resolved neighbour makes both ends pressable`() throws {
        let (context, _) = try makeSeriesWorld(episodes: twoSeasons)
        let resolved = neighbours(for: episodeMedia(season: 1, episode: 2), in: context)

        #expect(resolved.buttonState(for: .previous) == .enabled)
        #expect(resolved.buttonState(for: .next) == .enabled)
    }

    @Test func `a series with no episode rows yet keeps the buttons, disabled`() throws {
        let (context, _) = try makeSeriesWorld(episodes: [])
        let resolved = neighbours(for: episodeMedia(season: 1, episode: 1), in: context)

        #expect(resolved.buttonState(for: .previous) == .disabled)
        #expect(resolved.buttonState(for: .next) == .disabled)
    }

    @Test func `a movie hides the transport pair entirely`() throws {
        let (context, _) = try makeSeriesWorld(episodes: twoSeasons)
        let movie = try PlayableMedia(
            id: "movie-m-3",
            url: #require(URL(string: "http://example.com/movie/m-3.mp4")),
            title: "Film",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("m-3")
        )
        let resolved = neighbours(for: movie, in: context)

        #expect(resolved.buttonState(for: .previous) == .hidden)
        #expect(resolved.buttonState(for: .next) == .hidden)
    }

    /// A series edge dims one end only — it is a known absence, not an unknown
    /// one, so the other end stays pressable.
    @Test func `the series premiere dims previous and keeps next`() throws {
        let (context, _) = try makeSeriesWorld(episodes: twoSeasons)
        let resolved = neighbours(for: episodeMedia(season: 1, episode: 1), in: context)

        #expect(resolved.buttonState(for: .previous) == .disabled)
        #expect(resolved.buttonState(for: .next) == .enabled)
    }
}
