import Foundation
@testable import Lume
import Testing

struct TimeshiftTests {
    @Test func `archives keep provider seeking while live channels can buffer`() throws {
        let live = try #require(URL(string: "https://example.com/live/channel.m3u8"))
        let archive = try #require(URL(string: "https://example.com/timeshift/channel.m3u8"))
        #expect(TimeshiftEligibility.allows(isLive: true, url: live, enabled: true))
        #expect(!TimeshiftEligibility.allows(isLive: false, url: archive, enabled: true))
        #expect(!TimeshiftEligibility.allows(isLive: true, url: live, enabled: false))
        #expect(!TimeshiftEligibility.allows(isLive: true, url: live.deletingPathExtension().appendingPathExtension("ts"), enabled: true))
    }

    @Test func `resolves segments and discontinuities`() throws {
        let playlist = try TimeshiftPlaylist(text: """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:41
        #EXTINF:5.5,
        one.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6,
        ../two.ts
        """, baseURL: #require(URL(string: "https://example.com/live/index.m3u8")))
        #expect(playlist.segments.map(\.sequence) == [41, 42])
        #expect(playlist.targetDuration == 6)
        #expect(playlist.segments[0].url.absoluteString == "https://example.com/live/one.ts")
        #expect(playlist.segments[1].url.absoluteString == "https://example.com/two.ts")
        #expect(playlist.segments[1].discontinuity)
    }

    @Test(arguments: ["#EXT-X-KEY:METHOD=AES-128,URI=key", "#EXT-X-MAP:URI=init.mp4",
                      "#EXT-X-STREAM-INF:BANDWIDTH=100", "#EXT-X-BYTERANGE:100@0"])
    func `unsupported input is not silently corrupted`(tag: String) throws {
        #expect(throws: TimeshiftPlaylist.ParseError.unsupported) {
            try TimeshiftPlaylist(text: "#EXTM3U\n\(tag)\n", baseURL: #require(URL(string: "https://example.com/")))
        }
    }

    @Test func `invalid duration is rejected`() throws {
        #expect(throws: TimeshiftPlaylist.ParseError.malformed) {
            try TimeshiftPlaylist(text: "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:nan,\na.ts",
                                  baseURL: #require(URL(string: "https://example.com/")))
        }
    }

    @Test func `eviction keeps absolute positions and expires paused point`() throws {
        var window = try TimeshiftWindow(durationLimit: 12, byteLimit: 100)
        _ = try window.append(id: 1, duration: 6, bytes: 20)
        _ = try window.append(id: 2, duration: 6, bytes: 20)
        let removed = try window.append(id: 3, duration: 6, bytes: 20)
        #expect(removed.map(\.id) == [1])
        #expect(window.start == 6)
        #expect(window.end == 18)
        #expect(window.clamped(2) == 6)
        #expect(window.clamped(99) == 18)
        #expect(window.behindLive(at: 12) == 6)
    }

    @Test func `byte limit and duplicate segments`() throws {
        var window = try TimeshiftWindow(durationLimit: 900, byteLimit: 100)
        _ = try window.append(id: 1, duration: 5, bytes: 60)
        #expect(try window.append(id: 1, duration: 5, bytes: 60).isEmpty)
        #expect(window.end == 5)
        #expect(window.totalBytes == 60)
        let removed = try window.append(id: 2, duration: 5, bytes: 60)
        #expect(removed.map(\.id) == [1])
        #expect(window.totalBytes == 60)
        #expect(throws: TimeshiftWindow.WindowError.self) {
            try window.append(id: 3, duration: 5, bytes: 101)
        }
        #expect(window.end == 10)
    }
}

struct TimeshiftIntegrationTests {
    @Test func `retains media and serves only indexed segments`() async throws {
        guard let base = ProcessInfo.processInfo.environment["LUME_TIMESHIFT_FIXTURE"], let source = URL(string: base) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = try TimeshiftCache(directory: directory, durationLimit: 12)
        try await cache.ingest(url: source)
        let snapshot = await cache.snapshot()
        #expect(snapshot.finished)
        #expect(snapshot.end == 30)
        #expect(snapshot.end - snapshot.start <= 12)
        #expect(snapshot.bytes > 0)
        let server = try TimeshiftServer(cache: cache)
        let baseURL = try await server.start()
        let sequence = try #require(snapshot.entries.first?.id)
        let (playlist, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("\(sequence)/index.m3u8"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = try #require(String(data: playlist, encoding: .utf8))
        #expect(text.contains("segment-\(sequence).ts"))
        #expect(!text.contains(source.host ?? "example.com"))
        let (segment, segmentResponse) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("\(sequence)/segment-\(sequence).ts"))
        #expect((segmentResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(!segment.isEmpty)
        let (_, missingResponse) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("\(sequence)/segment-999999.ts"))
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
        server.stop()
        try await cache.close()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
