import Foundation

/// Measured, monotonically increasing media positions, independent of wall time.
/// The cache owner deletes only the entries returned by append, after reads end.
nonisolated struct TimeshiftWindow {
    struct Entry: Equatable {
        let id: Int64
        let start: TimeInterval
        let duration: TimeInterval
        let bytes: Int64
        var end: TimeInterval {
            start + duration
        }
    }

    enum WindowError: Error {
        case invalidSegment
    }

    private(set) var entries: [Entry] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var end: TimeInterval = 0
    let durationLimit: TimeInterval
    let byteLimit: Int64

    init(durationLimit: TimeInterval = 900, byteLimit: Int64 = 1_073_741_824) throws {
        guard durationLimit.isFinite, durationLimit > 0, byteLimit > 0 else {
            throw WindowError.invalidSegment
        }
        self.durationLimit = durationLimit
        self.byteLimit = byteLimit
    }

    var start: TimeInterval {
        entries.first?.start ?? end
    }

    var isSeekable: Bool {
        !entries.isEmpty
    }

    /// Duplicate ingestion cannot extend the clock or count bytes twice.
    /// A single oversized segment is rejected, so the byte cap stays strict.
    mutating func append(id: Int64, duration: TimeInterval, bytes: Int64) throws -> [Entry] {
        guard duration.isFinite, duration > 0, duration <= durationLimit,
              bytes > 0, bytes <= byteLimit, (end + duration).isFinite
        else {
            throw WindowError.invalidSegment
        }
        if let last = entries.last, id <= last.id { return [] }
        var removed: [Entry] = []
        // Subtract before adding to avoid Int64 overflow at large configured caps.
        while let first = entries.first,
              totalBytes > byteLimit - bytes || end + duration - first.start > durationLimit
        {
            removed.append(entries.removeFirst())
            totalBytes -= first.bytes
        }
        entries.append(Entry(id: id, start: end, duration: duration, bytes: bytes))
        totalBytes += bytes
        end += duration
        return removed
    }

    func clamped(_ position: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return start }
        return min(max(position, start), end)
    }

    func behindLive(at position: TimeInterval) -> TimeInterval {
        max(0, end - clamped(position))
    }
}
