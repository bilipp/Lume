import Foundation
@testable import Lume
import Testing

struct ImageDiskCacheTests {
    @Test func `disk cache returns stored bytes`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = Data(repeating: 0xA1, count: 32)

        fixture.cache.store(data, for: "poster")

        #expect(fixture.cache.data(for: "poster") == data)
    }

    @Test func `maintenance expires files past the freshness window`() throws {
        let clock = TestClock()
        let fixture = try Fixture(maxAge: 60, clock: clock)
        defer { fixture.remove() }
        fixture.cache.store(Data(repeating: 0xA2, count: 32), for: "stale")

        clock.advance(by: 61)
        let result = fixture.cache.performMaintenance()

        #expect(result.expiredFiles == 1)
        #expect(result.bytesAfter == 0)
        #expect(fixture.cache.data(for: "stale") == nil)
    }

    @Test func `maintenance evicts least recently used files to its low water mark`() throws {
        let clock = TestClock()
        let fixture = try Fixture(byteLimit: 100, clock: clock)
        defer { fixture.remove() }

        fixture.cache.store(Data(repeating: 0xA1, count: 40), for: "oldest")
        clock.advance(by: 1)
        fixture.cache.store(Data(repeating: 0xA2, count: 40), for: "middle")
        clock.advance(by: 1)
        fixture.cache.store(Data(repeating: 0xA3, count: 40), for: "newest")

        let result = fixture.cache.performMaintenance()

        #expect(result.bytesBefore == 120)
        #expect(result.bytesAfter == 80)
        #expect(result.evictedFiles == 1)
        #expect(fixture.cache.data(for: "oldest") == nil)
        #expect(fixture.cache.data(for: "middle") != nil)
        #expect(fixture.cache.data(for: "newest") != nil)
    }

    @Test func `a cache hit refreshes LRU recency without extending freshness`() throws {
        let clock = TestClock()
        let fixture = try Fixture(byteLimit: 100, maxAge: 60, clock: clock)
        defer { fixture.remove() }

        fixture.cache.store(Data(repeating: 0xA1, count: 40), for: "used")
        clock.advance(by: 1)
        fixture.cache.store(Data(repeating: 0xA2, count: 40), for: "unused")
        clock.advance(by: 1)
        #expect(fixture.cache.data(for: "used") != nil)
        clock.advance(by: 1)
        fixture.cache.store(Data(repeating: 0xA3, count: 40), for: "newest")

        _ = fixture.cache.performMaintenance()

        #expect(fixture.cache.data(for: "used") != nil)
        #expect(fixture.cache.data(for: "unused") == nil)
        #expect(fixture.cache.data(for: "newest") != nil)

        clock.advance(by: 58)
        #expect(fixture.cache.data(for: "used") == nil)
    }

    @Test func `oversized image is not persisted`() throws {
        let fixture = try Fixture(byteLimit: 16)
        defer { fixture.remove() }

        fixture.cache.store(Data(repeating: 0xA1, count: 17), for: "oversized")

        #expect(fixture.cache.data(for: "oversized") == nil)
    }
}

private extension ImageDiskCacheTests {
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date.now

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    struct Fixture {
        let directory: URL
        let cache: ImageDiskCache

        init(
            byteLimit: Int64 = 1024,
            maxAge: TimeInterval = 3600,
            clock: TestClock = TestClock()
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImageDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cache = ImageDiskCache(
                directory: directory,
                byteLimit: byteLimit,
                maxAge: maxAge,
                automaticallyMaintains: false,
                now: clock.now
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
