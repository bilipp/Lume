//
//  LiveChannelRecentsRingCombinedTests.swift
//  LumeTests
//
//  Recently Watched surfing from Combined walks the rail Combined shows: the
//  newest `LiveChannelQuery.recentlyWatched` cap across every playlist, then
//  scoped to the members. A ring that scoped first would hold each member's
//  own newest rows instead, channels the rail never showed.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveChannelRecentsRingCombinedTests {
    /// Watched channels per playlist. Three playlists exceed `recentLimit`
    /// together while the two members alone already reach it, so capping first
    /// and scoping first give different lists.
    private let perPlaylist = 30

    private func streamID(_ playlist: Playlist, _ index: Int) -> String {
        "\(playlist.id.uuidString)-live-\(100 + index)"
    }

    /// Three playlists whose watched channels alternate in time — A0 newest,
    /// then B0, C0, A1… — so the global newest 50 holds about a third of each.
    private func makeInterleavedWorld(in context: ModelContext) throws -> [Playlist] {
        let playlists = ["A", "B", "C"].map {
            Playlist(name: $0, serverURL: "http://\($0.lowercased()).example.com", username: "u", password: "p")
        }
        for playlist in playlists {
            context.insert(playlist)
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0 ..< perPlaylist {
            for (rank, playlist) in playlists.enumerated() {
                let stream = LiveStream(
                    id: streamID(playlist, index),
                    streamId: 100 + index,
                    name: "Channel \(index)",
                    num: index + 1,
                    categoryId: "\(playlist.id.uuidString)-cat"
                )
                stream.lastWatchedDate = base.addingTimeInterval(-Double(index * 3 + rank) * 60)
                context.insert(stream)
            }
        }
        try context.save()
        return playlists
    }

    private func railChannels(_ catalogScope: CatalogScope, in context: ModelContext) throws -> [LiveStream] {
        let page = try context.fetch(LiveChannelQuery.descriptor(for: .recentlyWatched, sort: .playlist))
        return LiveChannelQuery.scoped(
            page, scope: .recentlyWatched, catalogScope: catalogScope, restriction: ContentRestriction()
        )
    }

    @Test func `combined recents walk the capped then scoped rail`() throws {
        try OnDiskCatalogStore.withContext { context in
            let playlists = try makeInterleavedWorld(in: context)
            let (first, second, outsider) = (playlists[0], playlists[1], playlists[2])
            let members = LiveSurfScope(playlistIDs: [first.id, second.id])
            let expected = try railChannels(members.catalogScope(owner: first.id), in: context).map(\.id)

            // The cap has to have cut into the members, or the walk proves nothing.
            #expect(expected.count < perPlaylist * 2)
            #expect(expected.contains(streamID(second, 0)))
            #expect(!expected.contains { $0.hasPrefix(outsider.id.uuidString) })

            let startID = streamID(first, 0)
            let startIndex = try #require(expected.firstIndex(of: startID))
            var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == startID })
            descriptor.fetchLimit = 1
            let stream = try #require(try context.fetch(descriptor).first)
            var current = try #require(PlayableMedia.from(
                stream: stream, playlist: first, scope: .recentlyWatched, surfScope: members
            ))

            var walked: [String] = []
            for _ in 0 ..< expected.count {
                let next = try #require(LiveChannelNavigator.adjacentMedia(
                    for: current, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
                ))
                guard case let .live(id) = next.contentRef else {
                    Issue.record("surfed to non-live media")
                    return
                }
                walked.append(id)
                current = next
            }

            for step in walked.indices {
                let position = (startIndex + step + 1) % expected.count
                #expect(walked[step] == expected[position], "step \(step + 1)")
            }
            #expect(current.surfScope == members)
        }
    }

    @Test func `recents without a surf scope stay in the channels playlist`() throws {
        try OnDiskCatalogStore.withContext { context in
            let playlists = try makeInterleavedWorld(in: context)
            let first = playlists[0]
            let startID = streamID(first, 0)
            var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == startID })
            descriptor.fetchLimit = 1
            let stream = try #require(try context.fetch(descriptor).first)
            let media = try #require(PlayableMedia.from(stream: stream, playlist: first, scope: .recentlyWatched))

            let next = try #require(LiveChannelNavigator.adjacentMedia(
                for: media, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
            ))

            #expect(next.contentRef == .live(streamID(first, 1)))
        }
    }
}
