//
//  LiveChannelHistoryTests.swift
//  LumeTests
//
//  Covers the live channel "recall" pair — the last-watched channel the tvOS
//  player jumps back to on a right press (`LiveChannelHistory`).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveChannelHistoryTests {
    /// Mirrors the id scheme ContentSyncManager writes:
    /// "<playlistUUID>-live-<streamId>".
    private func makeWorld(
        streams: [(num: Int, name: String, category: String)]
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

        for (offset, spec) in streams.enumerated() {
            let streamId = 100 + offset
            let stream = LiveStream(
                id: "\(playlist.id.uuidString)-live-\(streamId)",
                streamId: streamId,
                name: spec.name,
                num: spec.num,
                categoryId: spec.category
            )
            context.insert(stream)
        }
        try context.save()
        return (context, playlist)
    }

    private func media(
        forStreamId streamId: Int,
        playlist: Playlist,
        in context: ModelContext
    ) throws -> PlayableMedia {
        let id = "\(playlist.id.uuidString)-live-\(streamId)"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let stream = try #require(try context.fetch(descriptor).first)
        return try #require(PlayableMedia.from(stream: stream, playlist: playlist))
    }

    /// A throwaway defaults suite so the recall keys never touch real settings
    /// and parallel tests don't collide.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "LiveChannelHistoryTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    private let threeChannels: [(num: Int, name: String, category: String)] = [
        (num: 1, name: "Alpha", category: "cat-a"),
        (num: 2, name: "Bravo", category: "cat-a"),
        (num: 3, name: "Charlie", category: "cat-a")
    ]

    // MARK: - Recall

    @Test func `recall returns the previously watched channel`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let delta = try media(forStreamId: 102, playlist: playlist, in: context)

        LiveChannelHistory.record(alpha, defaults: defaults)
        LiveChannelHistory.record(delta, defaults: defaults)

        let recalled = LiveChannelHistory.recallMedia(in: context, defaults: defaults)
        #expect(recalled?.contentRef == alpha.contentRef)
    }

    @Test func `recall is nil with no prior channel`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        LiveChannelHistory.record(alpha, defaults: defaults)

        #expect(LiveChannelHistory.recallMedia(in: context, defaults: defaults) == nil)
    }

    @Test func `recall toggles between the two most recent channels`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        LiveChannelHistory.record(alpha, defaults: defaults)
        LiveChannelHistory.record(bravo, defaults: defaults)
        // On Bravo, recall points at Alpha.
        #expect(LiveChannelHistory.recallMedia(in: context, defaults: defaults)?.contentRef == alpha.contentRef)

        // Acting on the recall (switching to Alpha) records it, so recall now
        // points back at Bravo — the classic last-button toggle.
        LiveChannelHistory.record(alpha, defaults: defaults)
        #expect(LiveChannelHistory.recallMedia(in: context, defaults: defaults)?.contentRef == bravo.contentRef)
    }

    @Test func `reselecting the current channel leaves recall untouched`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        LiveChannelHistory.record(alpha, defaults: defaults)
        LiveChannelHistory.record(bravo, defaults: defaults)
        // Re-recording the current channel must not push Bravo into "previous".
        LiveChannelHistory.record(bravo, defaults: defaults)

        #expect(LiveChannelHistory.recallMedia(in: context, defaults: defaults)?.contentRef == alpha.contentRef)
    }

    @Test func `non-live media does not clobber the recall pair`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let movie = try #require(PlayableMedia.from(
            movie: Movie(id: "m-1", streamId: 1, name: "Film", containerExtension: "mp4"),
            playlist: playlist
        ))

        LiveChannelHistory.record(alpha, defaults: defaults)
        LiveChannelHistory.record(bravo, defaults: defaults)
        // A VOD detour between channels must leave the live recall intact.
        LiveChannelHistory.record(movie, defaults: defaults)

        #expect(LiveChannelHistory.recallMedia(in: context, defaults: defaults)?.contentRef == alpha.contentRef)
    }

    // MARK: - Recents list

    /// The id `record` stores for a stream — "<playlistUUID>-live-<streamId>".
    private func channelId(forStreamId streamId: Int, playlist: Playlist) -> String {
        "\(playlist.id.uuidString)-live-\(streamId)"
    }

    @Test func `recents lists watched channels most-recent first`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let charlie = try media(forStreamId: 102, playlist: playlist, in: context)

        LiveChannelHistory.record(alpha, defaults: defaults)
        LiveChannelHistory.record(bravo, defaults: defaults)
        LiveChannelHistory.record(charlie, defaults: defaults)

        #expect(LiveChannelHistory.recentChannelIds(defaults: defaults) == [
            channelId(forStreamId: 102, playlist: playlist),
            channelId(forStreamId: 101, playlist: playlist),
            channelId(forStreamId: 100, playlist: playlist)
        ])
    }

    @Test func `re-watching a channel moves it to the front without duplicating`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        LiveChannelHistory.record(alpha, defaults: defaults)
        LiveChannelHistory.record(bravo, defaults: defaults)
        LiveChannelHistory.record(alpha, defaults: defaults)

        #expect(LiveChannelHistory.recentChannelIds(defaults: defaults) == [
            channelId(forStreamId: 100, playlist: playlist),
            channelId(forStreamId: 101, playlist: playlist)
        ])
    }

    @Test func `non-live media stays out of the recents list`() throws {
        let (_, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let movie = try #require(PlayableMedia.from(
            movie: Movie(id: "m-1", streamId: 1, name: "Film", containerExtension: "mp4"),
            playlist: playlist
        ))

        LiveChannelHistory.record(movie, defaults: defaults)

        #expect(LiveChannelHistory.recentChannelIds(defaults: defaults).isEmpty)
    }

    // MARK: - Profile scoping

    @Test func `recents and recall are isolated per profile`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let profileA = UUID()
        let profileB = UUID()

        LiveChannelHistory.record(alpha, profileID: profileA, defaults: defaults)
        LiveChannelHistory.record(bravo, profileID: profileA, defaults: defaults)

        // Profile A sees its own recents and recall pair.
        #expect(LiveChannelHistory.recentChannelIds(profileID: profileA, defaults: defaults) == [
            channelId(forStreamId: 101, playlist: playlist),
            channelId(forStreamId: 100, playlist: playlist)
        ])
        #expect(LiveChannelHistory.recallMedia(in: context, profileID: profileA, defaults: defaults)?
            .contentRef == alpha.contentRef)

        // Profile B starts empty — A's history doesn't leak across.
        #expect(LiveChannelHistory.recentChannelIds(profileID: profileB, defaults: defaults).isEmpty)
        #expect(LiveChannelHistory.recallMedia(in: context, profileID: profileB, defaults: defaults) == nil)
    }

    @Test func `the default profile reuses an upgrading user's existing history`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        // Pre-profiles data: recorded with no profile (legacy un-suffixed keys).
        LiveChannelHistory.record(alpha, profileID: nil, defaults: defaults)
        LiveChannelHistory.record(bravo, profileID: nil, defaults: defaults)

        // The default profile reads the same un-suffixed keys, so the history
        // carries over after the upgrade.
        #expect(LiveChannelHistory.recentChannelIds(
            profileID: UserProfile.defaultProfileID, defaults: defaults
        ) == [
            channelId(forStreamId: 101, playlist: playlist),
            channelId(forStreamId: 100, playlist: playlist)
        ])
    }

    @Test func `purge clears a profile's history`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let defaults = try makeDefaults()
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let profile = UUID()

        LiveChannelHistory.record(alpha, profileID: profile, defaults: defaults)
        LiveChannelHistory.record(bravo, profileID: profile, defaults: defaults)
        LiveChannelHistory.purge(profileID: profile, defaults: defaults)

        #expect(LiveChannelHistory.recentChannelIds(profileID: profile, defaults: defaults).isEmpty)
        #expect(LiveChannelHistory.recallMedia(in: context, profileID: profile, defaults: defaults) == nil)
    }
}
