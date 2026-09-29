//
//  StoreRelocationTests.swift
//  LumeTests
//
//  The one-time move of a SwiftData store out of the app-group container: the
//  store travels with its sidecars, an interrupted move finishes next launch,
//  and an existing store at the destination is never overwritten.
//

import Foundation
@testable import Lume
import Testing

struct StoreRelocationTests {
    private let fileManager = FileManager.default

    private func makeDirectories() throws -> (group: URL, app: URL) {
        let root = fileManager.temporaryDirectory.appending(path: "relocation-\(UUID().uuidString)")
        let group = root.appending(path: "group/Library/Application Support")
        let app = root.appending(path: "app/Library/Application Support")
        try fileManager.createDirectory(at: group, withIntermediateDirectories: true)
        return (group, app)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func `moves the store with its sidecars and support directory`() throws {
        let (group, app) = try makeDirectories()
        try write("main", to: group.appending(path: "CloudUserData.store"))
        try write("wal", to: group.appending(path: "CloudUserData.store-wal"))
        try write("shm", to: group.appending(path: "CloudUserData.store-shm"))
        let support = group.appending(path: ".CloudUserData_SUPPORT")
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try write("asset", to: support.appending(path: "asset"))
        // Another store's files in the same directory stay where they are.
        try write("other", to: group.appending(path: "default.store"))

        StoreRelocation.moveOutOfAppGroup(
            from: group.appending(path: "CloudUserData.store"),
            to: app.appending(path: "CloudUserData.store")
        )

        #expect(try read(app.appending(path: "CloudUserData.store")) == "main")
        #expect(try read(app.appending(path: "CloudUserData.store-wal")) == "wal")
        #expect(try read(app.appending(path: "CloudUserData.store-shm")) == "shm")
        #expect(try read(app.appending(path: ".CloudUserData_SUPPORT/asset")) == "asset")
        #expect(!fileManager.fileExists(atPath: group.appending(path: "CloudUserData.store").path))
        #expect(fileManager.fileExists(atPath: group.appending(path: "default.store").path))
    }

    @Test func `finishes a move that stopped before the main file`() throws {
        let (group, app) = try makeDirectories()
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        // The previous launch moved the sidecars, then stopped.
        try write("wal", to: app.appending(path: "default.store-wal"))
        try write("main", to: group.appending(path: "default.store"))

        StoreRelocation.moveOutOfAppGroup(
            from: group.appending(path: "default.store"),
            to: app.appending(path: "default.store")
        )

        #expect(try read(app.appending(path: "default.store")) == "main")
        #expect(try read(app.appending(path: "default.store-wal")) == "wal")
    }

    @Test func `never overwrites a store already at the destination`() throws {
        let (group, app) = try makeDirectories()
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        try write("legacy", to: group.appending(path: "default.store"))
        try write("current", to: app.appending(path: "default.store"))

        StoreRelocation.moveOutOfAppGroup(
            from: group.appending(path: "default.store"),
            to: app.appending(path: "default.store")
        )

        #expect(try read(app.appending(path: "default.store")) == "current")
        #expect(try read(group.appending(path: "default.store")) == "legacy")
    }

    @Test func `does nothing when the store is already in place`() throws {
        let (group, _) = try makeDirectories()
        let store = group.appending(path: "default.store")
        try write("main", to: store)

        StoreRelocation.moveOutOfAppGroup(from: store, to: store)

        #expect(try read(store) == "main")
    }
}
