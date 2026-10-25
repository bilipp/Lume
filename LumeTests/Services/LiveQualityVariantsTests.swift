//
//  LiveQualityVariantsTests.swift
//  LumeTests
//
//  Covers the player's live quality switch resolution
//  (`LiveQualityVariants.resolve`): which channels of a playlist count as the
//  playing channel in another quality, and how they are ordered.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveQualityVariantsTests {
    private struct StreamSpec {
        var name: String
        var category: String
        var isHidden = false
    }

    /// Seeds `streams` into one playlist, numbering them from stream id 100, and
    /// `others` into a second playlist from stream id 500.
    private func makeWorld(
        streams: [StreamSpec],
        others: [StreamSpec] = []
    ) throws -> (ModelContext, Playlist) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        let other = Playlist(name: "Other", serverURL: "http://other.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        context.insert(other)
        for (owner, specs, base) in [(playlist, streams, 100), (other, others, 500)] {
            for (offset, spec) in specs.enumerated() {
                let streamId = base + offset
                let stream = LiveStream(
                    id: "\(owner.id.uuidString)-live-\(streamId)",
                    streamId: streamId,
                    name: spec.name,
                    num: streamId,
                    categoryId: spec.category
                )
                stream.isHidden = spec.isHidden
                context.insert(stream)
            }
        }
        try context.save()
        return (context, playlist)
    }

    private func media(
        forStreamId streamId: Int,
        playlist: Playlist,
        scope: LiveChannelScope? = .category("cat-sport"),
        in context: ModelContext
    ) throws -> PlayableMedia {
        let id = "\(playlist.id.uuidString)-live-\(streamId)"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let stream = try #require(try context.fetch(descriptor).first)
        return try #require(PlayableMedia.from(stream: stream, playlist: playlist, scope: scope))
    }

    private func streamID(_ streamId: Int, _ playlist: Playlist) -> String {
        "\(playlist.id.uuidString)-live-\(streamId)"
    }

    private func variants(
        for media: PlayableMedia,
        restriction: ContentRestriction = ContentRestriction(),
        in context: ModelContext
    ) -> [LiveQualityVariantOption] {
        LiveQualityVariants.resolve(for: media, restriction: restriction, in: context)
    }

    // MARK: - Matching

    @Test func `variants come from the whole playlist, across categories`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 4K", category: "cat-4k"),
            StreamSpec(name: "DE: Lume Sport 2 HD", category: "cat-sport")
        ])
        let playing = try media(forStreamId: 100, playlist: playlist, in: context)

        let found = variants(for: playing, in: context)
        #expect(found.map(\.id) == [streamID(101, playlist), streamID(100, playlist)])
    }

    @Test func `another playlist's copy is never offered`() throws {
        let (context, playlist) = try makeWorld(
            streams: [StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport")],
            others: [StreamSpec(name: "DE: Lume Sport 1 UHD", category: "cat-sport")]
        )
        let playing = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(variants(for: playing, in: context).isEmpty)
    }

    @Test func `hidden channels are excluded`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 FHD", category: "cat-sport", isHidden: true),
            StreamSpec(name: "DE: Lume Sport 1 UHD", category: "cat-sport")
        ])
        let playing = try media(forStreamId: 100, playlist: playlist, in: context)

        let ids = variants(for: playing, in: context).map(\.id)
        #expect(ids == [streamID(102, playlist), streamID(100, playlist)])
    }

    @Test func `a locked category's copies are excluded`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 4K", category: "cat-4k")
        ])
        let playing = try media(forStreamId: 100, playlist: playlist, in: context)
        let locked = ContentRestriction(isActive: true, restrictedCategoryIDs: ["cat-4k"])

        #expect(variants(for: playing, restriction: locked, in: context).isEmpty)
        #expect(variants(for: playing, in: context).count == 2)
    }

    @Test func `channel 1 never pairs with channel 10`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 10 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 10 FHD", category: "cat-sport")
        ])
        let playing = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(variants(for: playing, in: context).isEmpty)
    }

    @Test func `other countries and timeshift feeds never pair`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Rivo HD", category: "cat-de"),
            StreamSpec(name: "AT: Rivo FHD", category: "cat-at"),
            StreamSpec(name: "DE: Rivo +1 FHD", category: "cat-de"),
            StreamSpec(name: "DE: Rivoneo HD", category: "cat-de")
        ])
        let playing = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(variants(for: playing, in: context).isEmpty)
    }

    // MARK: - Ordering

    @Test func `best quality first, untagged last, current included`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 UHD", category: "cat-4k"),
            StreamSpec(name: "DE: Lume Sport 1 FHD", category: "cat-sport")
        ])
        let playing = try media(forStreamId: 101, playlist: playlist, in: context)

        let found = variants(for: playing, in: context)
        #expect(found.map(\.tag) == ["UHD", "FHD", "HD", nil])
        #expect(found.map(\.name) == ["DE: Lume Sport 1 UHD", "DE: Lume Sport 1 FHD", "DE: Lume Sport 1 HD", "DE: Lume Sport 1"])
        #expect(found.contains { $0.id == streamID(101, playlist) })
    }

    @Test func `targets keep the launch scope`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 4K", category: "cat-4k")
        ])
        let playing = try media(forStreamId: 100, playlist: playlist, scope: .favorites, in: context)

        let target = try #require(variants(for: playing, in: context).first { $0.id != streamID(100, playlist) }?.target)
        #expect(target.contentRef == .live(streamID(101, playlist)))
        #expect(target.channelScope == .favorites)
    }

    // MARK: - Gates

    @Test func `catch-up resolves nothing`() throws {
        let (context, playlist) = try makeWorld(streams: [
            StreamSpec(name: "DE: Lume Sport 1 HD", category: "cat-sport"),
            StreamSpec(name: "DE: Lume Sport 1 4K", category: "cat-4k")
        ])
        let live = try media(forStreamId: 100, playlist: playlist, in: context)
        let catchup = PlayableMedia(
            id: "catchup-\(streamID(100, playlist))-0",
            url: live.url,
            title: live.title,
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .live(streamID(100, playlist))
        )

        #expect(variants(for: catchup, in: context).isEmpty)
    }

    @Test func `search words are the key's longest`() {
        #expect(LiveQualityVariants.searchWords(in: "de: lume sport 1") == ["sport", "lume", "de", "1"])
        #expect(LiveQualityVariants.searchWords(in: "|uk| northbeam one") == ["northbeam", "one", "uk"])
        #expect(LiveQualityVariants.searchWords(in: "lmx") == ["lmx"])
    }
}
