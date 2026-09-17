import Foundation

/// Live progress for a single active or queued download.
///
/// A per-item `@Observable` box rather than a value in the `activeDownloads`
/// dictionary: `@Observable` tracks access at stored-property granularity, so
/// views that read a *value* out of the dictionary observe the whole
/// dictionary — every progress tick for any download re-rendered every
/// visible episode card. With a box, ticks mutate the box's own properties
/// and only the card rendering that download re-renders; the dictionary
/// itself changes only when a download starts, finishes, or fails.
@Observable
final class ActiveDownload: Identifiable {
    let id: String
    let title: String
    var fractionCompleted: Double
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    /// Ring-buffer of (timestamp, cumulative bytes) used for speed estimation.
    /// Capped at 5 seconds of history; populated at most every 500 ms.
    var samples: [(date: Date, bytes: Int64)] = []

    init(id: String, title: String, fractionCompleted: Double = 0) {
        self.id = id
        self.title = title
        self.fractionCompleted = fractionCompleted
    }

    /// Bytes per second averaged over the sample window, or nil if too few samples.
    var speedBytesPerSec: Double? {
        guard samples.count >= 2 else { return nil }
        let elapsed = samples.last!.date.timeIntervalSince(samples.first!.date)
        guard elapsed > 0.3 else { return nil }
        return Double(samples.last!.bytes - samples.first!.bytes) / elapsed
    }

    /// Estimated seconds remaining based on current speed, or nil if unknown.
    var estimatedSecondsRemaining: Double? {
        guard let speed = speedBytesPerSec, speed > 0, totalBytes > bytesWritten else { return nil }
        return Double(totalBytes - bytesWritten) / speed
    }

    /// Human-readable "3.2 MB/s · 2 min" caption, or nil while still measuring.
    var statsLine: String? {
        guard fractionCompleted > 0, let speed = speedBytesPerSec, speed > 0 else { return nil }
        let speedStr = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .memory) + "/s"
        guard let eta = estimatedSecondsRemaining, eta > 1 else { return speedStr }
        let etaStr = Duration.seconds(eta).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        return "\(speedStr) · \(etaStr)"
    }
}

struct PendingDownload {
    let id: String
    let title: String
    let url: URL
    let filename: String
}

/// The per-task state the delegate needs, carried on the task itself.
///
/// A background session's tasks live in `nsurlsessiond` and outlive the app
/// process, so none of `DownloadManager`'s in-memory maps are guaranteed to
/// exist when a callback arrives — the app may have been relaunched purely to
/// receive it. `URLSessionTask.taskDescription` is persisted with the task by
/// the daemon, so encoding this alongside the transfer makes every callback
/// self-describing: `didFinishDownloadingTo` can compute the destination and
/// move the file without touching the main actor at all.
nonisolated struct DownloadTaskInfo: Codable {
    let id: String
    let title: String
    let filename: String

    init(id: String, title: String, filename: String) {
        self.id = id
        self.title = title
        self.filename = filename
    }

    init?(taskDescription: String?) {
        guard let data = taskDescription?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DownloadTaskInfo.self, from: data)
        else { return nil }
        self = decoded
    }

    var taskDescription: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
