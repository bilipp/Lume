//
//  OnDiskCatalogStore.swift
//  LumeTests
//
//  A catalog container backed by a real store file, for the suites whose subject
//  is SQLite's own behaviour.
//
//  `makeTestContainer()` is `isStoredInMemoryOnly: true`, and an in-memory
//  SwiftData store evaluates predicates and sort descriptors in Swift. Anything
//  that depends on SQLite disagreeing with Swift — a collation, a NULL
//  placement, an index the planner does or doesn't pick — is therefore
//  structurally invisible to it. Modelled on `PerfStore.makeOnDiskContainer()`,
//  which lives in the `LumePerformanceTests` target and cannot be imported here.
//

import Foundation
@testable import Lume
import SwiftData

nonisolated enum OnDiskCatalogStore {
    /// The catalog schema, matching `LumeApp.makeModelContainers` and
    /// `makeTestContainer()`.
    static var catalogSchema: Schema {
        Schema([
            Playlist.self,
            Lume.Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self,
            EPGSource.self
        ])
    }

    /// Runs `body` against a context on a real store file in its own temp
    /// directory, removed when `body` returns.
    ///
    /// Scoped rather than handed back on purpose. The store file has to outlive
    /// every fetch made through it, and a container returned to a test that
    /// parks it in a `_` binding is released at once — taking the file with it
    /// and failing the next fetch with `NSFileReadUnknownError`, several lines
    /// away from the binding that caused it.
    static func withContext<T>(_ body: (ModelContext) throws -> T) throws -> T {
        let schema = catalogSchema
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // `cloudKitDatabase: .none` is mandatory: the catalog's
        // `@Attribute(.unique)` models fail container load under the default
        // `.automatic` on an entitled simulator host.
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("nav.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        return try body(ModelContext(container))
    }
}
