import Foundation

/// A segment boundary is a decode starting point, not the requested playhead.
nonisolated struct TimeshiftSeekTarget: Equatable {
    let sequence: Int64
    let origin: TimeInterval
    let offset: TimeInterval

    init?(position: TimeInterval, entries: [TimeshiftWindow.Entry]) {
        guard position.isFinite, let first = entries.first, let last = entries.last else { return nil }
        let clamped = min(max(position, first.start), max(first.start, last.end - 0.1))
        guard let entry = entries.last(where: { $0.start <= clamped }) else { return nil }
        sequence = entry.id
        origin = entry.start
        offset = clamped - entry.start
    }
}
