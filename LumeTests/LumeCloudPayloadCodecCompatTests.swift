//
//  LumeCloudPayloadCodecCompatTests.swift
//  LumeTests
//
//  Playlist payloads written by clients that predate a field still open: a
//  missing `disabledContentRaw` means "fetch everything". Its own suite so
//  `LumeCloudPayloadCodecTests` stays within the type-length limit.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Testing

@MainActor
struct LumeCloudPayloadCodecCompatTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
    }

    @Test func `a playlist written before content switches existed still opens`() throws {
        let playlist = SyncedPlaylist(
            id: UUID(), name: "Older", serverURL: "http://provider.example", username: "u", password: "p",
            sourceTypeRaw: PlaylistSourceType.xtream.rawValue, epgURL: nil, syncEnabled: true,
            hiddenTabsRaw: "liveTV", updatedAt: Date(timeIntervalSince1970: 1_760_000_123.456)
        )
        container.mainContext.insert(playlist)
        var payload = try LumeCloudPayload.decode(Codec.encoded(playlist, previous: nil))
        payload.data.removeValue(forKey: "disabledContentRaw")

        let decoded = try Codec.makeModel(from: payload, as: SyncedPlaylist.self)
        #expect(decoded.hiddenTabsRaw == "liveTV")
        #expect(decoded.disabledContentRaw.isEmpty)
    }

    @Test func `a playlist payload carries the content switches`() throws {
        let playlist = SyncedPlaylist(
            id: UUID(), name: "Newer", serverURL: "http://provider.example", username: "u", password: "p",
            sourceTypeRaw: PlaylistSourceType.xtream.rawValue, epgURL: nil, syncEnabled: true,
            disabledContentRaw: "movies,series", updatedAt: Date(timeIntervalSince1970: 1_760_000_123.456)
        )
        container.mainContext.insert(playlist)
        let payload = try LumeCloudPayload.decode(Codec.encoded(playlist, previous: nil))
        #expect(payload.data["disabledContentRaw"] == .string("movies,series"))
    }
}
