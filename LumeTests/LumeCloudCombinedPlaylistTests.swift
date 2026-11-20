//
//  LumeCloudCombinedPlaylistTests.swift
//  LumeTests
//
//  A playlist's Combined setup (`combinedTypesRaw`, `combinedPriority`) on
//  Lume Cloud. The fields stay out of the payload until a record holds a setup,
//  so a playlist outside Combined keeps the bytes it had before they existed
//  and never reads as changed. A payload without them was written by a client
//  that doesn't know them, and leaves the row's own setup alone, even when the
//  server's side wins a conflict. The mirror is an in-memory Lume Cloud
//  container (`cloudKitDatabase: .none`).
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Testing

@MainActor
struct LumeCloudCombinedPlaylistTests {
    private typealias Codec = LumeCloudPayloadCodec

    private let container: ModelContainer
    private let keys = LumeCloudKeys.generate()
    private let server: StubLumeCloudClient
    private let playlistID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01")!
    private let created = Date(timeIntervalSince1970: 1_760_000_000)
    private let edited = Date(timeIntervalSince1970: 1_760_000_100)

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
        server = StubLumeCloudClient(keys: keys)
    }

    // MARK: Helpers

    private func makeTransport() throws -> LumeCloudTransport {
        try LumeCloudTransport(client: server, container: container, rootKey: keys.rootKey, accountId: "acct-harbor")
    }

    private func playlist(
        name: String = "Harbor Lights",
        combinedTypesRaw: String = "",
        combinedPriority: Int? = nil,
        updatedAt: Date? = nil
    ) -> SyncedPlaylist {
        SyncedPlaylist(
            id: playlistID, name: name, serverURL: "http://provider.example:8080",
            username: "viewer", password: "secret", sourceTypeRaw: PlaylistSourceType.xtream.rawValue,
            epgURL: nil, syncEnabled: true, combinedTypesRaw: combinedTypesRaw,
            combinedPriority: combinedPriority, updatedAt: updatedAt ?? created
        )
    }

    private func rows<Model: PersistentModel>(_: Model.Type) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }

    private func state() throws -> LumeCloudRecordState? {
        try rows(LumeCloudRecordState.self).first { $0.logicalKey == Codec.playlistKey(id: playlistID) }
    }

    private func editLocal(_ edit: (SyncedPlaylist) -> Void) throws {
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        edit(row)
        try context.save()
    }

    // MARK: Codec

    @Test func `a playlist outside Combined carries no combined fields`() {
        let payload = Codec.payload(for: playlist(), previous: nil)

        #expect(payload.data["combinedTypesRaw"] == nil)
        #expect(payload.data["combinedPriority"] == nil)
        #expect(payload.data["hiddenTabsRaw"] == .string(""))
    }

    @Test func `a combined setup round-trips`() throws {
        let bytes = try Codec.encoded(playlist(combinedTypesRaw: "movies,liveTV", combinedPriority: 2), previous: nil)
        let payload = try LumeCloudPayload.decode(bytes)
        #expect(payload.data["combinedTypesRaw"] == .string("movies,liveTV"))
        #expect(payload.data["combinedPriority"] == .number(2))

        let decoded = try Codec.makeModel(from: payload, as: SyncedPlaylist.self)
        #expect(decoded.combinedTypesRaw == "movies,liveTV")
        #expect(decoded.combinedPriority == 2)
        #expect(try Codec.encoded(decoded, previous: nil) == bytes)
    }

    @Test func `a priority alone is carried`() {
        let payload = Codec.payload(for: playlist(combinedPriority: 0), previous: nil)

        #expect(payload.data["combinedTypesRaw"] == nil)
        #expect(payload.data["combinedPriority"] == .number(0))
    }

    @Test func `leaving Combined writes the defaults over a synced setup`() throws {
        let previous = try Codec.encoded(playlist(combinedTypesRaw: "liveTV", combinedPriority: 1), previous: nil)

        let payload = Codec.payload(for: playlist(), previous: previous)

        #expect(payload.data["combinedTypesRaw"] == .string(""))
        #expect(payload.data["combinedPriority"] == .null)
        let decoded = try Codec.makeModel(from: payload, as: SyncedPlaylist.self)
        #expect(decoded.combinedTypesRaw.isEmpty)
        #expect(decoded.combinedPriority == nil)
    }

    @Test func `a payload without the combined fields leaves the row's setup alone`() throws {
        let row = playlist(combinedTypesRaw: "series", combinedPriority: 3)

        try Codec.apply(Codec.payload(for: playlist(name: "Harbor Lights HD"), previous: nil), to: row)

        #expect(row.name == "Harbor Lights HD")
        #expect(row.combinedTypesRaw == "series")
        #expect(row.combinedPriority == 3)
    }

    @Test func `a new row from a payload without the combined fields is outside Combined`() throws {
        let decoded = try Codec.makeModel(from: Codec.payload(for: playlist(), previous: nil), as: SyncedPlaylist.self)

        #expect(decoded.combinedTypesRaw.isEmpty)
        #expect(decoded.combinedPriority == nil)
    }

    // MARK: Transport

    @Test func `a synced playlist outside Combined is not pushed again`() async throws {
        let transport = try makeTransport()
        try server.upsert(Codec.payload(for: playlist(), previous: nil))
        try await transport.pull()

        try await transport.push()

        #expect(server.pushes.isEmpty)
        #expect(try state()?.isDirty == false)
    }

    @Test func `a remote edit without the combined fields keeps the local setup and pushes it`() async throws {
        let transport = try makeTransport()
        try server.upsert(Codec.payload(for: playlist(), previous: nil))
        try await transport.pull()
        try editLocal { $0.combinedTypesRaw = "liveTV"; $0.combinedPriority = 0 }

        try server.upsert(Codec.payload(for: playlist(name: "Harbor Lights HD", updatedAt: edited), previous: nil))
        try await transport.pull()

        let row = try #require(try rows(SyncedPlaylist.self).first)
        #expect(row.name == "Harbor Lights HD")
        #expect(row.combinedTypesRaw == "liveTV")
        #expect(row.combinedPriority == 0)
        #expect(try state()?.isDirty == true)

        try await transport.push()
        let pushed = try #require(server.pushes.last?.first)
        let payload = try LumeCloudPayload.decode(keys.open(#require(pushed.ciphertext), rid: pushed.rid))
        #expect(payload.data["name"] == .string("Harbor Lights HD"))
        #expect(payload.data["combinedTypesRaw"] == .string("liveTV"))
        #expect(payload.data["combinedPriority"] == .number(0))
    }

    @Test func `a remote setup and a remote clear both apply`() async throws {
        let transport = try makeTransport()
        let combined = try Codec.encoded(playlist(combinedTypesRaw: "movies", combinedPriority: 1), previous: nil)
        try server.upsert(LumeCloudPayload.decode(combined))
        try await transport.pull()
        #expect(try rows(SyncedPlaylist.self).first?.combinedTypesRaw == "movies")

        try server.upsert(Codec.payload(for: playlist(updatedAt: edited), previous: combined))
        try await transport.pull()

        let row = try #require(try rows(SyncedPlaylist.self).first)
        #expect(row.combinedTypesRaw.isEmpty)
        #expect(row.combinedPriority == nil)
        #expect(try state()?.isDirty == false)
    }
}
