import Foundation
import OSLog
import SwiftData

extension DownloadManager {
    /// Settles catalog items still marked `pending`/`downloading` that the
    /// restored session knows nothing about.
    ///
    /// Two things strand them: the user force-quitting Lume (which makes the
    /// system cancel its background transfers outright), and the app being
    /// suspended after the file was moved but before the SwiftData write landed.
    /// Disk is the authority for telling those apart — if the file is there the
    /// download did finish, whatever the stored status says.
    nonisolated static func recoverInterruptedDownloads(
        liveIDs: Set<String>,
        directory: URL,
        container: ModelContainer
    ) async {
        let pending = DownloadStatus.pending.rawValue
        let downloading = DownloadStatus.downloading.rawValue
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []

        /// The finished file for `id`, if one is already on disk.
        func downloadedFile(for id: String) -> URL? {
            let sanitized = sanitize(id)
            return files.first { $0.deletingPathExtension().lastPathComponent == sanitized }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let movies = try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
                $0.downloadStatusRaw == pending || $0.downloadStatusRaw == downloading
            }))
            let episodes = try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate {
                $0.downloadStatusRaw == pending || $0.downloadStatusRaw == downloading
            }))
            var recovered = 0
            for movie in movies where !liveIDs.contains(movie.id) {
                let file = downloadedFile(for: movie.id)
                movie.downloadStatus = file == nil ? .failed : .completed
                movie.localFileURL = file?.path
                movie.downloadedAt = file == nil ? nil : Date()
                recovered += 1
            }
            for episode in episodes where !liveIDs.contains(episode.id) {
                let file = downloadedFile(for: episode.id)
                episode.downloadStatus = file == nil ? .failed : .completed
                episode.localFileURL = file?.path
                episode.downloadedAt = file == nil ? nil : Date()
                recovered += 1
            }
            guard recovered > 0 else { return }
            try context.save()
            Logger.downloads.info("Recovered \(recovered) interrupted download(s)")
        } catch {
            Logger.downloads.error("Failed to recover interrupted downloads: \(error)")
        }
    }
}
