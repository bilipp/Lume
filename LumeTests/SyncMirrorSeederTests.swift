//
//  SyncMirrorSeederTests.swift
//  LumeTests
//
//  What a backend switch copies from the old mirror into the new one: every
//  profile, sports follow and recording server, the content state of the
//  profiles that aren't active, merged into rows the target already has with
//  the collection's conflict rule. In-memory stores, `cloudKitDatabase: .none`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SyncMirrorSeederTests {
    private let active = UUID()
    private let juniper = UUID()

    private func makeMirror() throws -> ModelContainer {
        try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
    }

    private func rows<Model: PersistentModel>(_: Model.Type, in container: ModelContainer) throws -> [Model] {
        try ModelContext(container).fetch(FetchDescriptor<Model>())
    }

    @Test func `copies mirror-only rows and skips the active profile's content`() async throws {
        let source = try makeMirror()
        let target = try makeMirror()
        let context = ModelContext(source)
        context.insert(UserProfile(id: juniper, name: "Juniper"))
        context.insert(UserContentState(contentId: "item-a", kind: .movie, profileID: juniper, isFavorite: true))
        context.insert(UserContentState(contentId: "item-b", kind: .movie, profileID: active, isFavorite: true))
        context.insert(SyncedSportsFollow(key: "soccer/team/fictional", profileID: juniper))
        context.insert(SyncedRecordingServer(name: "Attic Recorder", baseURL: "http://recorder.invalid", token: "secret"))
        context.insert(SyncedPlaylist(
            id: UUID(), name: "Projected Elsewhere", serverURL: "http://x", username: "u", password: "p",
            sourceTypeRaw: "xtream", epgURL: nil, syncEnabled: true
        ))
        try context.save()

        let snapshot = try await SyncMirrorSeeder.snapshot(of: source, activeProfileID: active)
        let inserted = try await SyncMirrorSeeder.seed(snapshot, into: target)

        #expect(inserted == 4)
        #expect(try rows(UserProfile.self, in: target).map(\.id) == [juniper])
        #expect(try rows(UserContentState.self, in: target).map(\.contentId) == ["item-a"])
        #expect(try rows(SyncedSportsFollow.self, in: target).map(\.profileID) == [juniper])
        #expect(try rows(SyncedRecordingServer.self, in: target).map(\.token) == ["secret"])
        #expect(try rows(SyncedPlaylist.self, in: target).isEmpty)
    }

    @Test func `rows without a profile count as the default profile's`() async throws {
        let source = try makeMirror()
        let target = try makeMirror()
        let context = ModelContext(source)
        context.insert(UserContentState(contentId: "item-none", kind: .movie, profileID: nil, isWatched: true))
        try context.save()

        let whileDefaultActive = try await SyncMirrorSeeder.snapshot(of: source, activeProfileID: UserProfile.defaultProfileID)
        #expect(whileDefaultActive.payloads.isEmpty)

        try await SyncMirrorSeeder.seed(SyncMirrorSeeder.snapshot(of: source, activeProfileID: active), into: target)
        #expect(try rows(UserContentState.self, in: target).map(\.contentId) == ["item-none"])
    }

    @Test func `an existing row is merged: the newer edit wins and a child profile stays a child`() async throws {
        let source = try makeMirror()
        let target = try makeMirror()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(60)
        let sourceContext = ModelContext(source)
        sourceContext.insert(UserProfile(id: juniper, name: "Juniper Renamed", isChild: false, updatedAt: new))
        try sourceContext.save()
        let targetContext = ModelContext(target)
        targetContext.insert(UserProfile(id: juniper, name: "Juniper", isChild: true, updatedAt: old))
        try targetContext.save()

        let inserted = try await SyncMirrorSeeder.seed(SyncMirrorSeeder.snapshot(of: source, activeProfileID: active), into: target)

        #expect(inserted == 0)
        let merged = try rows(UserProfile.self, in: target)
        #expect(merged.count == 1)
        #expect(merged.first?.name == "Juniper Renamed")
        #expect(merged.first?.isChild == true)
    }

    @Test func `the same store as source and target keeps its rows`() async throws {
        let store = try makeMirror()
        let context = ModelContext(store)
        context.insert(UserProfile(id: juniper, name: "Juniper"))
        try context.save()

        try await SyncMirrorSeeder.seed(SyncMirrorSeeder.snapshot(of: store, activeProfileID: active), into: store)

        #expect(try rows(UserProfile.self, in: store).map(\.id) == [juniper])
    }
}
