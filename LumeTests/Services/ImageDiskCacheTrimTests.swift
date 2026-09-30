//
//  ImageDiskCacheTrimTests.swift
//  LumeTests
//
//  The image disk cache evicts least recently used files once it outgrows its
//  limit, and a read counts as a use.
//

import Foundation
@testable import Lume
import Testing

struct ImageDiskCacheTrimTests {
    private func makeCache() -> ImageDiskCache {
        ImageDiskCache(directory: FileManager.default.temporaryDirectory.appending(path: "image-cache-\(UUID().uuidString)"))
    }

    /// Stores `count` files of `size` bytes, oldest first, a minute apart.
    private func fill(_ cache: ImageDiskCache, count: Int, size: Int) throws {
        let payload = Data(repeating: 0xAB, count: size)
        let start = Date().addingTimeInterval(-Double(count) * 60)
        for index in 0 ..< count {
            cache.store(payload, for: "image-\(index)")
            let file = try #require(try FileManager.default.contentsOfDirectory(
                at: cache.directoryURL, includingPropertiesForKeys: [.contentModificationDateKey]
            ).first { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    > Date().addingTimeInterval(-5)
            })
            try FileManager.default.setAttributes(
                [.modificationDate: start.addingTimeInterval(Double(index) * 60)], ofItemAtPath: file.path
            )
        }
    }

    @Test func `a cache under its limit is left alone`() throws {
        let cache = makeCache()
        try fill(cache, count: 5, size: 64 * 1024)

        #expect(cache.trim(limit: 10 * 1024 * 1024, target: 5 * 1024 * 1024) == 0)
        #expect((0 ..< 5).allSatisfy { cache.data(for: "image-\($0)") != nil })
    }

    @Test func `the least recently used files go first, and a read counts as a use`() throws {
        let cache = makeCache()
        try fill(cache, count: 10, size: 64 * 1024)
        // The oldest file is read, so it is now the most recently used.
        #expect(cache.data(for: "image-0") != nil)

        let removed = cache.trim(limit: 400 * 1024, target: 300 * 1024)

        #expect(removed > 0)
        #expect(cache.data(for: "image-0") != nil)
        #expect(cache.data(for: "image-1") == nil)
        #expect(cache.data(for: "image-9") != nil)
    }
}
