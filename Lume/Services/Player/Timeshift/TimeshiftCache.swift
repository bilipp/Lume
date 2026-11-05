import Foundation

/// One upstream HLS ingest, independent of whether the presentation is paused.
/// A playback adapter serves the retained playlist and segments to the engine.
actor TimeshiftCache {
    struct Snapshot {
        let entries: [TimeshiftWindow.Entry]
        let start: TimeInterval
        let end: TimeInterval
        let bytes: Int64
        let playlist: String
        let finished: Bool
    }

    enum CacheError: Error {
        case invalidResponse
        case lowDiskSpace
        case sourceRestarted
    }

    private let directory: URL
    private let session: URLSession
    private var window: TimeshiftWindow
    private var segments: [Int64: TimeshiftPlaylist.Segment] = [:]
    private var latestSequence: Int64?
    private var targetDuration: TimeInterval = 1
    private var finished = false
    private var closed = false
    private var ingesting = false

    init(directory: URL, durationLimit: TimeInterval = 900, byteLimit: Int64 = 1_073_741_824) throws {
        self.directory = directory
        window = try TimeshiftWindow(durationLimit: durationLimit, byteLimit: byteLimit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Caller owns cancellation/retry policy. Errors preserve already captured
    /// content. Never run two ingest loops for the same playback session.
    func ingest(url: URL, headers: [String: String] = [:]) async throws {
        guard !closed, !ingesting else { throw CancellationError() }
        ingesting = true
        defer { ingesting = false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        while !Task.isCancelled {
            let (data, response) = try await fetch(url, headers: headers)
            guard let text = String(data: data, encoding: .utf8) else { throw CacheError.invalidResponse }
            try checkActive()
            let playlist = try TimeshiftPlaylist(text: text, baseURL: response.url ?? url)
            try await capture(playlist, headers: headers)
            if playlist.isFinished { return }
            try await Task.sleep(for: .seconds(max(0.5, playlist.targetDuration / 2)))
        }
        try Task.checkCancellation()
    }

    private func capture(_ playlist: TimeshiftPlaylist, headers: [String: String]) async throws {
        if let latestSequence, let last = playlist.segments.last, last.sequence < latestSequence {
            throw CacheError.sourceRestarted
        }
        targetDuration = playlist.targetDuration
        for segment in playlist.segments {
            try Task.checkCancellation()
            if let latestSequence, segment.sequence <= latestSequence { continue }
            if let latestSequence, segment.sequence > latestSequence + 1 {
                throw CacheError.sourceRestarted
            }
            // Bound every response; capture runs independently of the decoder.
            let (payload, response) = try await fetch(segment.url, headers: headers, limit: min(window.byteLimit, 67_108_864))
            try checkActive()
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                throw CacheError.invalidResponse
            }
            let bytes = Int64(payload.count)
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard free > bytes + 104_857_600 else { throw CacheError.lowDiskSpace }
            var proposed = window
            let evicted = try proposed.append(id: segment.sequence, duration: segment.duration, bytes: bytes)
            let destination = fileURL(id: segment.sequence)
            try payload.write(to: destination, options: .atomic)
            window = proposed
            segments[segment.sequence] = segment
            latestSequence = segment.sequence
            for old in evicted {
                segments.removeValue(forKey: old.id)
                try? FileManager.default.removeItem(at: fileURL(id: old.id))
            }
        }
        finished = playlist.isFinished
    }

    func snapshot(from firstSequence: Int64? = nil) -> Snapshot {
        let retained = window.entries.filter { entry in firstSequence.map { entry.id >= $0 } ?? true }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(ceil(targetDuration)))",
                     "#EXT-X-MEDIA-SEQUENCE:\(retained.first?.id ?? 0)"]
        lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
        for entry in retained {
            if segments[entry.id]?.discontinuity == true { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append("#EXTINF:\(entry.duration),")
            lines.append("segment-\(entry.id).ts")
        }
        if finished { lines.append("#EXT-X-ENDLIST") }
        return Snapshot(entries: window.entries, start: window.start, end: window.end, bytes: window.totalBytes,
                        playlist: lines.joined(separator: "\n") + "\n", finished: finished)
    }

    /// Returns only indexed filenames; callers cannot request arbitrary paths.
    /// Reading on the actor serializes deletion against a segment response.
    func segment(id: Int64) throws -> Data? {
        guard segments[id] != nil else { return nil }
        return try Data(contentsOf: fileURL(id: id), options: .mappedIfSafe)
    }

    func close() throws {
        closed = true
        session.invalidateAndCancel()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func fileURL(id: Int64) -> URL {
        directory.appendingPathComponent("segment-\(id).ts")
    }

    private func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        return request
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func fetch(_ url: URL, headers: [String: String], limit: Int64 = 1_048_576) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request(url, headers: headers))
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              response.expectedContentLength <= limit else { throw CacheError.invalidResponse }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw CacheError.invalidResponse }
            data.append(byte)
        }
        try checkActive()
        return (data, response)
    }
}
