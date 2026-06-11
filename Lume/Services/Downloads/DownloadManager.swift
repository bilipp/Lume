import Foundation
import OSLog
import SwiftData

// MARK: - Data types

/// Progress snapshot for a single active or queued download.
struct ActiveDownload: Identifiable {
    let id: String
    let title: String
    var fractionCompleted: Double = 0
}

private struct PendingDownload {
    let id: String
    let title: String
    let url: URL
    let filename: String
}

// MARK: - DownloadManager

/// Central download manager. Serialises file downloads, persists completion
/// state into SwiftData, and exposes live progress to the UI.
///
/// Not available on tvOS — the download feature targets iOS and macOS only.
@MainActor
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // MARK: - Settings keys

    static let maxConcurrentKey = "downloads.maxConcurrent"
    static let autoDeleteKey = "downloads.autoDeleteAfterWatching"

    // MARK: - Public observable state

    /// Actively downloading items, keyed by content id.
    private(set) var activeDownloads: [String: ActiveDownload] = [:]
    /// Content ids that are queued but not yet started.
    private(set) var pendingIDs: Set<String> = []

    // MARK: - Private

    var modelContainer: ModelContainer?

    private var session: URLSession!
    private var taskMap: [Int: String] = [:]
    private var idToTask: [String: URLSessionDownloadTask] = [:]
    private var idToFilename: [String: String] = [:]
    private var pendingQueue: [PendingDownload] = []

    // MARK: - Init

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 0
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        ensureDownloadsDirectory()
    }

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        modelContainer = container
    }

    // MARK: - Public API

    func startDownload(movie: Movie, playlist: Playlist) {
        let id = movie.id
        guard activeDownloads[id] == nil, !pendingIDs.contains(id) else { return }
        guard movie.downloadStatus != .completed else { return }

        let directURL = movie.directURL.flatMap(URL.init(string:))
        guard let url = directURL ?? XtreamClient().buildMovieURL(for: movie, playlist: playlist) else { return }

        let ext = movie.containerExtension ?? "mp4"
        let filename = "\(sanitize(id)).\(ext)"
        idToFilename[id] = filename
        enqueue(PendingDownload(id: id, title: movie.name, url: url, filename: filename))
    }

    func startDownload(episode: Episode, playlist: Playlist) {
        let id = episode.id
        guard activeDownloads[id] == nil, !pendingIDs.contains(id) else { return }
        guard episode.downloadStatus != .completed else { return }

        let directURL = playlist.sourceType == .m3u
            ? episode.directSource.flatMap(URL.init(string:))
            : nil
        guard let url = directURL ?? XtreamClient().buildEpisodeURL(for: episode, playlist: playlist) else { return }

        let ext = episode.containerExtension
        let filename = "\(sanitize(id)).\(ext)"
        let title = episode.series.map { "\($0.name) S\(episode.seasonNum)E\(episode.episodeNum)" } ?? episode.title
        idToFilename[id] = filename
        enqueue(PendingDownload(id: id, title: title, url: url, filename: filename))
    }

    func cancelDownload(id: String) {
        idToTask[id]?.cancel()
        idToTask.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
        pendingIDs.remove(id)
        pendingQueue.removeAll { $0.id == id }
        scheduleModelUpdate(id: id, status: nil, localURL: nil)
    }

    func deleteLocalFile(id: String) {
        let filename = idToFilename[id]
        if let filename {
            let fileURL = downloadsDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            let sanitizedID = sanitize(id)
            let all = (try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in all where file.deletingPathExtension().lastPathComponent == sanitizedID {
                try? FileManager.default.removeItem(at: file)
            }
        }
        scheduleModelUpdate(id: id, status: nil, localURL: nil)
    }

    /// If auto-delete is enabled, removes the local file after the content is
    /// marked watched. Call this whenever watched state changes to `true`.
    func checkAutoDelete(id: String) {
        guard UserDefaults.standard.bool(forKey: Self.autoDeleteKey) else { return }
        deleteLocalFile(id: id)
    }

    // MARK: - Status helpers

    func isActive(_ id: String) -> Bool {
        activeDownloads[id] != nil || pendingIDs.contains(id)
    }

    // MARK: - Directory

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - Private

    private func ensureDownloadsDirectory() {
        try? FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
    }

    private var maxConcurrent: Int {
        let raw = UserDefaults.standard.integer(forKey: Self.maxConcurrentKey)
        return raw > 0 ? raw : 1
    }

    private func enqueue(_ item: PendingDownload) {
        pendingQueue.append(item)
        pendingIDs.insert(item.id)
        scheduleModelUpdate(id: item.id, status: .pending, localURL: nil)
        promoteIfNeeded()
    }

    private func promoteIfNeeded() {
        let max = maxConcurrent
        while activeDownloads.count < max, !pendingQueue.isEmpty {
            let item = pendingQueue.removeFirst()
            pendingIDs.remove(item.id)
            startTask(item)
        }
    }

    private func startTask(_ item: PendingDownload) {
        let task = session.downloadTask(with: item.url)
        taskMap[task.taskIdentifier] = item.id
        idToTask[item.id] = task
        activeDownloads[item.id] = ActiveDownload(id: item.id, title: item.title)
        scheduleModelUpdate(id: item.id, status: .downloading, localURL: nil)
        task.resume()
    }

    private func scheduleModelUpdate(id: String, status: DownloadStatus?, localURL: String?) {
        guard let container = modelContainer else { return }
        let capturedID = id
        let capturedStatus = status
        let capturedURL = localURL
        Task.detached {
            await DownloadManager.persistStatus(
                id: capturedID,
                status: capturedStatus,
                localURL: capturedURL,
                container: container
            )
        }
    }

    private nonisolated static func persistStatus(
        id: String,
        status: DownloadStatus?,
        localURL: String?,
        container: ModelContainer
    ) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var movieDesc = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            movieDesc.fetchLimit = 1
            if let movie = try context.fetch(movieDesc).first {
                movie.downloadStatus = status
                movie.localFileURL = localURL
                movie.downloadedAt = status == .completed ? Date() : nil
                try context.save()
                return
            }
            var epDesc = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            epDesc.fetchLimit = 1
            if let episode = try context.fetch(epDesc).first {
                episode.downloadStatus = status
                episode.localFileURL = localURL
                episode.downloadedAt = status == .completed ? Date() : nil
                try context.save()
            }
        } catch {
            Logger.downloads.error("Failed to persist download status for \(id): \(error)")
        }
    }

    private nonisolated func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            self.activeDownloads[self.taskMap[taskID] ?? ""]?.fractionCompleted = fraction
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let responseURL = downloadTask.response?.url ?? downloadTask.currentRequest?.url

        Task { @MainActor in
            guard let id = self.taskMap[taskID] else { return }

            let filename: String
            if let name = self.idToFilename[id] {
                filename = name
            } else {
                let ext = responseURL?.pathExtension ?? "mp4"
                filename = "\(self.sanitize(id)).\(ext)"
                self.idToFilename[id] = filename
            }

            let destination = self.downloadsDirectory.appendingPathComponent(filename)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                Logger.downloads.info("Download complete: \(id)")
                self.activeDownloads.removeValue(forKey: id)
                self.taskMap.removeValue(forKey: taskID)
                self.idToTask.removeValue(forKey: id)
                self.scheduleModelUpdate(id: id, status: .completed, localURL: destination.path)
            } catch {
                Logger.downloads.error("Failed to save download for \(id): \(error)")
                self.handleFailure(taskID: taskID, id: id)
            }
            self.promoteIfNeeded()
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskMap[taskID] else { return }
            Logger.downloads.error("Download failed for \(id): \(error)")
            self.handleFailure(taskID: taskID, id: id)
            self.promoteIfNeeded()
        }
    }

    @MainActor
    private func handleFailure(taskID: Int, id: String) {
        activeDownloads.removeValue(forKey: id)
        taskMap.removeValue(forKey: taskID)
        idToTask.removeValue(forKey: id)
        scheduleModelUpdate(id: id, status: .failed, localURL: nil)
    }
}
