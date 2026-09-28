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

    @Test func `launch maintenance waits before sweeping the cache`() async throws {
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDiskCacheLaunchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let delay = Duration.seconds(1)
        let launched = ContinuousClock.now
        let cache = ImageDiskCache(
            directory: directory,
            byteLimit: 1024,
            maxAge: 60,
            initialMaintenanceDelay: delay,
            now: clock.now
        )
        cache.store(Data(repeating: 0xA4, count: 32), for: "expired-after-launch")
        clock.advance(by: 61)

        // The entry is already expired according to the cache clock, but launch
        // maintenance must give foreground poster delivery a head start.
        try await Task.sleep(for: .milliseconds(100))
        let cachedFile = cache.fileURL(for: "expired-after-launch")
        let survivedLaunch = FileManager.default.fileExists(atPath: cachedFile.path)
        let checkedAfter = ContinuousClock.now - launched
        // In a loaded parallel run this task can wake seconds late — after the
        // sweep was *meant* to run — and then the check proves nothing. It is
        // only judged when it really happened inside the delay.
        if checkedAfter < delay {
            #expect(survivedLaunch, "Swept \(checkedAfter) after launch, before the \(delay) delay")
        }

        // The sweep runs at `.background` priority, so poll for it rather than
        // betting on one fixed sleep.
        let deadline = ContinuousClock.now + .seconds(10)
        while FileManager.default.fileExists(atPath: cachedFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!FileManager.default.fileExists(atPath: cachedFile.path))
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
