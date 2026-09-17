import Foundation
import os
import OSLog
import SwiftData

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

    /// Per-task time of the last published progress update. `didWriteData`
    /// fires for every received chunk (often 100+ times per second); publishing
    /// each one into the observable `activeDownloads` re-rendered every
    /// observing view per chunk and saturated the main thread — visibly
    /// delaying unrelated interactions such as opening a context menu. Gates
    /// updates to one per task per 250 ms.
    private nonisolated let progressPublishGate = OSAllocatedUnfairLock<[Int: Date]>(initialState: [:])

    private var session: URLSession!
    private var taskMap: [Int: String] = [:]
    private var idToTask: [String: URLSessionDownloadTask] = [:]
    private var idToFilename: [String: String] = [:]
    private var pendingQueue: [PendingDownload] = []

    /// Handed over by `UIApplicationDelegate` when the app is relaunched to
    /// receive background session events. Must be called once the session has
    /// finished delivering them, or the system considers the relaunch unfinished.
    private var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Init

    /// Identifier of the shared background session. Stable across launches —
    /// it is how the app reconnects to transfers `nsurlsessiond` is still running.
    private static let sessionIdentifier = "bilipp.Lume.downloads"

    override private init() {
        super.init()
        // A *background* configuration, not `.default`: a default session is
        // owned by the app process, so the system suspends it along with the app
        // and downloads stall the moment the user leaves Lume. A background
        // session hands the transfer to `nsurlsessiond`, which keeps running
        // while the app is suspended or terminated.
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Relaunch the app in the background to deliver completion events, so a
        // download that finishes while Lume is not running still gets its file
        // moved into place and its status persisted.
        config.sessionSendsLaunchEvents = true
        // These are user-initiated: the person tapped Download and expects it to
        // start now, not whenever the system next decides conditions are ideal.
        // (The default flips to `true` for sessions created while in the
        // background, so it has to be set explicitly rather than left alone.)
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 0
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        ensureDownloadsDirectory()
    }

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        modelContainer = container
    }

    /// Re-adopts whatever the background session is still transferring, then
    /// reconciles the catalog against it. Call once per launch, after
    /// `configure(container:)`.
    ///
    /// The session outlives the process, so after a relaunch `nsurlsessiond`
    /// still holds the tasks while every map here is empty. Each task carries
    /// its own `DownloadTaskInfo`, which is enough to rebuild them.
    func restoreBackgroundSession() async {
        var liveIDs: Set<String> = []
        for task in await session.allTasks {
            guard let download = task as? URLSessionDownloadTask,
                  let info = DownloadTaskInfo(taskDescription: task.taskDescription)
            else {
                // Nothing here can route this task's file to a destination —
                // an orphan from an older build, or a non-download task. Drop it
                // rather than leave it consuming bandwidth for no one.
                task.cancel()
                continue
            }
            liveIDs.insert(info.id)
            taskMap[task.taskIdentifier] = info.id
            idToTask[info.id] = download
            idToFilename[info.id] = info.filename
            let active = ActiveDownload(id: info.id, title: info.title)
            let expected = task.countOfBytesExpectedToReceive
            if expected > 0 {
                active.totalBytes = expected
                active.bytesWritten = task.countOfBytesReceived
                active.fractionCompleted = Double(task.countOfBytesReceived) / Double(expected)
            }
            activeDownloads[info.id] = active
        }
        Logger.downloads.info("Adopted \(liveIDs.count) in-flight background download(s)")
        // A leftover Live Activity has to be cleaned up when nothing is in
        // flight any more — a force-quit cancels the session's tasks and would
        // otherwise leave the banner up for hours. But if this launch happened
        // *to deliver* background events, those completions are still on their
        // way and belong in the closing summary, so leave ending it to
        // `urlSessionDidFinishEvents` once they have all landed.
        refreshLiveActivity(force: true, endsWhenIdle: backgroundCompletionHandler == nil)

        guard let container = modelContainer else { return }
        let capturedIDs = liveIDs
        let directory = downloadsDirectory
        Task.detached {
            await DownloadManager.recoverInterruptedDownloads(
                liveIDs: capturedIDs,
                directory: directory,
                container: container
            )
        }
    }

    /// Stores the completion handler the system hands over when it relaunches
    /// the app to deliver background session events, to be invoked from
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    ///
    /// Reaching this method is also what *recreates* the session: a background
    /// session only delivers its queued events to a session object built with
    /// the same identifier, and `DownloadManager.shared` is lazy, so a
    /// background relaunch would otherwise never touch it.
    func handleBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Public API

    func startDownload(movie: Movie, playlist: Playlist) {
        let id = movie.id
        // Stalker streams resolve to short-lived URLs per session, so there is no
        // stable URL to download for offline playback.
        guard playlist.supportsDownloads else { return }
        guard activeDownloads[id] == nil, !pendingIDs.contains(id) else { return }
        guard movie.downloadStatus != .completed else { return }

        let directURL = movie.directURL.flatMap(URL.init(string:))
        guard let url = directURL ?? XtreamClient().buildMovieURL(for: movie, playlist: playlist) else { return }

        let ext = movie.containerExtension ?? "mp4"
        let filename = "\(Self.sanitize(id)).\(ext)"
        idToFilename[id] = filename
        enqueue(PendingDownload(id: id, title: movie.name, url: url, filename: filename))
    }

    func startDownload(episode: Episode, playlist: Playlist) {
        let id = episode.id
        guard playlist.supportsDownloads else { return }
        guard activeDownloads[id] == nil, !pendingIDs.contains(id) else { return }
        guard episode.downloadStatus != .completed else { return }

        let directURL = playlist.sourceType == .m3u
            ? episode.directSource.flatMap(URL.init(string:))
            : nil
        guard let url = directURL ?? XtreamClient().buildEpisodeURL(for: episode, playlist: playlist) else { return }

        let ext = episode.containerExtension
        let filename = "\(Self.sanitize(id)).\(ext)"
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
        refreshLiveActivity(force: true)
    }

    func deleteLocalFile(id: String) {
        let filename = idToFilename[id]
        if let filename {
            let fileURL = downloadsDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            let sanitizedID = Self.sanitize(id)
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

    /// `nonisolated` so `didFinishDownloadingTo` can resolve the destination and
    /// move the file before returning, without hopping to the main actor first.
    nonisolated var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - Private

    private nonisolated func ensureDownloadsDirectory() {
        try? FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        Self.excludeFromBackup(downloadsDirectory)
    }

    /// Keeps downloaded media out of the user's iCloud / Finder backup.
    ///
    /// `Documents` is backed up by default, so a handful of downloaded films
    /// silently added gigabytes to the user's backup — against Apple's Data
    /// Storage Guidelines, which put content the app can fetch again but the
    /// user expects offline in exactly this "do not back up" bucket. Apps have
    /// been rejected over far smaller amounts.
    ///
    /// Set on the *directory*, which covers everything already inside it and
    /// everything added later, so individual downloads need no bookkeeping.
    ///
    /// Deliberately not `Library/Caches`, the other usual answer: the system may
    /// purge Caches under storage pressure, which would delete the film someone
    /// downloaded for a flight. This attribute gives the semantics actually
    /// wanted — not backed up, and never purged.
    ///
    /// Idempotent, and called on every launch rather than only at creation, so
    /// installs that already have a downloads directory are corrected too.
    nonisolated static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            // Not fatal — downloads still work, they just keep getting backed
            // up. Logged because the symptom (a bloated backup) is otherwise
            // invisible from inside the app.
            Logger.downloads.error("Failed to exclude downloads from backup: \(error.localizedDescription)")
        }
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
        // The single choke point every start, finish and failure funnels
        // through, so the Live Activity only needs one hook to see all three.
        refreshLiveActivity(force: true)
    }

    private func startTask(_ item: PendingDownload) {
        let task = session.downloadTask(with: item.url)
        task.taskDescription = DownloadTaskInfo(
            id: item.id, title: item.title, filename: item.filename
        ).taskDescription
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

    nonisolated static func sanitize(_ id: String) -> String {
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
        let now = Date()
        let shouldPublish = progressPublishGate.withLock { lastPublish in
            if let last = lastPublish[taskID], now.timeIntervalSince(last) < 0.25 {
                return false
            }
            lastPublish[taskID] = now
            return true
        }
        guard shouldPublish else { return }
        Task { @MainActor in
            guard let id = self.taskMap[taskID], let download = self.activeDownloads[id] else { return }
            download.fractionCompleted = fraction
            download.bytesWritten = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite
            // Add a speed sample at most every 500 ms to keep the stats stable.
            let lastSample = download.samples.last?.date ?? .distantPast
            if now.timeIntervalSince(lastSample) >= 0.5 {
                download.samples.append((date: now, bytes: totalBytesWritten))
                download.samples = download.samples.filter { $0.date >= now.addingTimeInterval(-5) }
            }
            self.refreshLiveActivity()
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let responseURL = downloadTask.response?.url ?? downloadTask.currentRequest?.url
        let ext = responseURL?.pathExtension.isEmpty == false ? responseURL!.pathExtension : "mp4"

        // Resolve the destination from the task itself rather than from any map
        // on the main actor: with a background session this callback can arrive
        // in a process that was relaunched purely to receive it, where those maps
        // are still empty.
        guard let info = DownloadTaskInfo(taskDescription: downloadTask.taskDescription) else {
            finishWithoutTaskInfo(taskID: taskID, location: location, ext: ext)
            return
        }

        // URLSession deletes `location` the moment this delegate returns, and the
        // process may be suspended before any hop to the main actor runs — so the
        // file has to reach its *final* home synchronously, right here.
        let destination = downloadsDirectory.appendingPathComponent(info.filename)
        do {
            try moveIntoDownloads(from: location, to: destination)
        } catch {
            Logger.downloads.error("Failed to save download for \(info.id): \(error)")
            Task { @MainActor in
                self.handleFailure(taskID: taskID, id: info.id)
                self.promoteIfNeeded()
            }
            return
        }
        Logger.downloads.info("Download complete: \(info.id)")
        Task { @MainActor in
            self.finalizeDownload(taskID: taskID, info: info, destination: destination)
        }
    }

    /// Moves a finished transfer into the downloads directory, replacing any
    /// previous file for the same item.
    private nonisolated func moveIntoDownloads(from location: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: downloadsDirectory, withIntermediateDirectories: true
        )
        // Re-apply in case the directory was removed and recreated since
        // launch — a recreated one would carry no exclusion, and every
        // download after that would start being backed up again.
        Self.excludeFromBackup(downloadsDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)
    }

    /// Completion path for a task whose `DownloadTaskInfo` could not be decoded.
    /// Only reachable if encoding it failed when the task was created — which,
    /// for three strings, it does not — but a finished multi-gigabyte transfer is
    /// not something to drop on an "impossible" branch. Stages the file out of
    /// `location` (which URLSession deletes on return) so the content id can be
    /// resolved from `taskMap` on the main actor.
    private nonisolated func finishWithoutTaskInfo(taskID: Int, location: URL, ext: String) {
        let interim = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-dl", isDirectory: true)
            .appendingPathComponent("\(taskID).\(ext)")
        var staged = true
        do {
            try FileManager.default.createDirectory(
                at: interim.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: interim.path) {
                try FileManager.default.removeItem(at: interim)
            }
            try FileManager.default.moveItem(at: location, to: interim)
        } catch {
            Logger.downloads.error("Failed to stage download for task \(taskID): \(error)")
            staged = false
        }
        Task { @MainActor in
            guard let id = self.taskMap[taskID] else {
                try? FileManager.default.removeItem(at: interim)
                return
            }
            let filename = self.idToFilename[id] ?? "\(Self.sanitize(id)).\(ext)"
            self.idToFilename[id] = filename
            let destination = self.downloadsDirectory.appendingPathComponent(filename)
            do {
                guard staged else { throw CocoaError(.fileNoSuchFile) }
                try self.moveIntoDownloads(from: interim, to: destination)
            } catch {
                Logger.downloads.error("Failed to save download for \(id): \(error)")
                try? FileManager.default.removeItem(at: interim)
                self.handleFailure(taskID: taskID, id: id)
                self.promoteIfNeeded()
                return
            }
            Logger.downloads.info("Download complete: \(id)")
            self.finalizeDownload(
                taskID: taskID,
                info: DownloadTaskInfo(id: id, title: id, filename: filename),
                destination: destination
            )
        }
    }

    /// Main-actor bookkeeping once the file is already in place: clear the live
    /// maps and persist the completed status.
    @MainActor
    private func finalizeDownload(taskID: Int, info: DownloadTaskInfo, destination: URL) {
        _ = progressPublishGate.withLock { $0.removeValue(forKey: taskID) }
        idToFilename[info.id] = info.filename
        activeDownloads.removeValue(forKey: info.id)
        taskMap.removeValue(forKey: taskID)
        idToTask.removeValue(forKey: info.id)
        scheduleModelUpdate(id: info.id, status: .completed, localURL: destination.path)
        noteLiveActivityCompleted()
        promoteIfNeeded()
    }

    nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        // Cancellation is the user tapping the X: `cancelDownload` has already
        // cleared the item's state and status, so recording a failure here would
        // resurrect the row as a failed download.
        if (error as? URLError)?.code == .cancelled {
            return
        }
        let taskID = task.taskIdentifier
        // As in `didFinishDownloadingTo`, the task may outlive the process that
        // started it, so `taskMap` is not guaranteed to know it.
        let restoredID = DownloadTaskInfo(taskDescription: task.taskDescription)?.id
        Task { @MainActor in
            guard let id = self.taskMap[taskID] ?? restoredID else { return }
            Logger.downloads.error("Download failed for \(id): \(error)")
            self.handleFailure(taskID: taskID, id: id)
            self.promoteIfNeeded()
        }
    }

    /// The session has delivered every event queued while the app was away.
    /// Releasing the stored handler tells the system the background relaunch is
    /// finished; failing to call it gets the app throttled out of future ones.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in
            // Every completion this relaunch carried is now counted, so the
            // Live Activity can close with a summary that includes them.
            self.refreshLiveActivity(force: true)
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    @MainActor
    private func handleFailure(taskID: Int, id: String) {
        _ = progressPublishGate.withLock { $0.removeValue(forKey: taskID) }
        activeDownloads.removeValue(forKey: id)
        taskMap.removeValue(forKey: taskID)
        idToTask.removeValue(forKey: id)
        scheduleModelUpdate(id: id, status: .failed, localURL: nil)
        noteLiveActivityFailed()
    }
}
