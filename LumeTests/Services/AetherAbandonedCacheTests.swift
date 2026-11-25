#if !os(visionOS)
    import Foundation
    @testable import Lume
    import Testing

    struct AetherAbandonedCacheTests {
        @Test func `leftover engine files are removed and everything else stays`() async throws {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
                .appendingPathComponent("abandoned-cache-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: root) }
            let session = root.appendingPathComponent("aether-segments/session", isDirectory: true)
            try manager.createDirectory(at: session, withIntermediateDirectories: true)
            try Data(count: 64).write(to: session.appendingPathComponent("seg-0-0.m4s"))
            let spool = root.appendingPathComponent("aether-software-packets-1", isDirectory: true)
            try manager.createDirectory(at: spool, withIntermediateDirectories: true)
            let interrupted = root.appendingPathComponent("lume-aether-abandoned-1", isDirectory: true)
            try manager.createDirectory(at: interrupted, withIntermediateDirectories: true)
            let playlist = root.appendingPathComponent("download.m3u")
            try Data(count: 8).write(to: playlist)

            let removed = await AetherAbandonedCaches.remove(in: root)

            #expect(removed == 2)
            #expect(try manager.contentsOfDirectory(atPath: root.path) == ["download.m3u"])
        }

        @Test func `an empty directory is left alone`() async throws {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
                .appendingPathComponent("abandoned-cache-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: root) }
            try manager.createDirectory(at: root, withIntermediateDirectories: true)

            #expect(await AetherAbandonedCaches.remove(in: root) == 0)
            #expect(try manager.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
#endif
