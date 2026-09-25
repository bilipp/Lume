//
//  LiveChannelRecentsRingTests.swift
//  LumeTests
//
//  Pins in-player surfing of the Recently Watched collection to the composition
//  of the rail it claims to walk. The rail caps at `LiveChannelQuery.recentLimit`
//  across every playlist and filters to the active one afterwards, so with two
//  playlists installed a navigator that filtered first would surf channels the
//  viewer was never shown.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveChannelRecentsRingTests {
    /// Watched channels per playlist. Two of these exceed `recentLimit` together
    /// while either alone stays under it, which is what makes the two
    /// compositions differ.
    private let perPlaylist = 40

    private func makePlaylist(named name: String, in context: ModelContext) -> Playlist {
        let playlist = Playlist(
            name: name,
            serverURL: "http://example.com:8080",
            username: "user",
            password: "pass"
        )
        context.insert(playlist)
        return playlist
    }

    /// Mirrors the id scheme `ContentSyncManager` writes — the playlist prefix is
    /// what both the rail's Swift filter and `PlaylistOwner` key off.
    private func streamID(_ playlist: Playlist, _ index: Int) -> String {
        "\(playlist.id.uuidString)-live-\(100 + index)"
    }

    /// Two playlists whose watched channels alternate in time: A0 is newest, then
    /// B0, then A1, then B1… so the global newest 50 holds 25 of each while
    /// either playlist alone has 40 to offer.
    private func makeInterleavedWorld() throws -> (ModelContext, Playlist, Playlist) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let first = makePlaylist(named: "A", in: context)
        let second = makePlaylist(named: "B", in: context)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0 ..< perPlaylist {
            for (rank, playlist) in [first, second].enumerated() {
                let stream = LiveStream(
                    id: streamID(playlist, index),
                    streamId: 100 + index,
                    name: "Channel \(index)",
                    num: index + 1,
                    categoryId: "\(playlist.id.uuidString)-cat"
                )
                stream.lastWatchedDate = base.addingTimeInterval(-Double(index * 2 + rank) * 60)
                context.insert(stream)
            }
        }
        try context.save()
        return (context, first, second)
    }

    private func media(
        id: String, playlist: Playlist, in context: ModelContext
    ) throws -> PlayableMedia {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let stream = try #require(try context.fetch(descriptor).first)
        return try #require(
            PlayableMedia.from(stream: stream, playlist: playlist, scope: .recentlyWatched)
        )
    }

    /// The rail's own composition, derived the way every Live TV surface derives
    /// it: fetch the capped descriptor, then scope the rows in Swift.
    private func railChannels(
        playlist: Playlist, in context: ModelContext
    ) throws -> [LiveStream] {
        let page = try context.fetch(LiveChannelQuery.descriptor(for: .recentlyWatched, sort: .playlist))
        return LiveChannelQuery.scoped(
            page,
            scope: .recentlyWatched,
            playlistPrefix: "\(playlist.id.uuidString)-",
            restriction: ContentRestriction()
        )
    }

    @Test func `surfing recently watched walks the rail the viewer sees`() throws {
        let (context, mine, _) = try makeInterleavedWorld()
        let expected = try railChannels(playlist: mine, in: context).map(\.id)

        // Without this the walk proves nothing: the rail must be showing fewer
        // channels than this playlist has watched, i.e. the global cap has to
        // have cut into it.
        #expect(expected.count < perPlaylist)
        #expect(expected.count > 1)

        let startIndex = try #require(expected.firstIndex(of: streamID(mine, 0)))
        var current = try media(id: expected[startIndex], playlist: mine, in: context)
        var walked: [String] = []
        for _ in 0 ..< expected.count {
            let next = try #require(LiveChannelNavigator.adjacentMedia(
                for: current, offset: 1, sort: .playlist,
                restriction: ContentRestriction(), in: context
            ))
            guard case let .live(id) = next.contentRef else {
                Issue.record("surfed to non-live media")
                return
            }
            walked.append(id)
            current = next
        }

        #expect(walked.count == expected.count)
        for step in walked.indices {
            let position = (startIndex + step + 1) % expected.count
            #expect(walked[step] == expected[position], "step \(step + 1)")
        }
    }
}
