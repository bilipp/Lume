import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite("Background download task info")
struct DownloadTaskInfoTests {
    @Test
    func `round-trips through taskDescription`() throws {
        let original = DownloadTaskInfo(
            id: "playlist-1:movie:42",
            title: "Big Buck Bunny",
            filename: "playlist-1_movie_42.mkv"
        )
        let description = try #require(original.taskDescription)
        let decoded = try #require(DownloadTaskInfo(taskDescription: description))

        #expect(decoded.id == original.id)
        #expect(decoded.title == original.title)
        #expect(decoded.filename == original.filename)
    }

    @Test
    func `returns nil for a missing or unrelated task description`() {
        #expect(DownloadTaskInfo(taskDescription: nil) == nil)
        #expect(DownloadTaskInfo(taskDescription: "") == nil)
        #expect(DownloadTaskInfo(taskDescription: "movie-42") == nil)
        #expect(DownloadTaskInfo(taskDescription: #"{"id":"a"}"#) == nil)
    }

    @Test
    func `path separators never leak into the filename`() {
        #expect(DownloadManager.sanitize("abc/def:123") == "abc_def_123")
    }
}

@Suite("Interrupted download recovery")
struct DownloadRecoveryTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeMovie(id: String, status: DownloadStatus?) -> Movie {
        let movie = Movie(id: id, streamId: 1, name: "Movie \(id)")
        movie.downloadStatus = status
        return movie
    }

    /// A throwaway downloads directory so the sweep's disk probe is deterministic.
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func `a stranded download whose file never landed is marked failed`() async throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = ModelContext(container)
        context.insert(makeMovie(id: "gone", status: .downloading))
        context.insert(makeMovie(id: "queued", status: .pending))
        try context.save()

        await DownloadManager.recoverInterruptedDownloads(
            liveIDs: [], directory: directory, container: container
        )

        let movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        #expect(movies.allSatisfy { $0.downloadStatus == .failed })
        #expect(movies.allSatisfy { $0.localFileURL == nil })
    }

    @Test
    func `a stranded download whose file did land is marked completed`() async throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Simulates the app being suspended after the delegate moved the file but
        // before the SwiftData write landed.
        let file = directory.appendingPathComponent("landed.mp4")
        try Data("video".utf8).write(to: file)

        let context = ModelContext(container)
        context.insert(makeMovie(id: "landed", status: .downloading))
        try context.save()

        await DownloadManager.recoverInterruptedDownloads(
            liveIDs: [], directory: directory, container: container
        )

        let movie = try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.downloadStatus == .completed)
        #expect(movie.localFileURL == "landed.mp4")
        #expect(movie.downloadedAt != nil)
    }

    @Test
    func `downloads the restored session is still running are left alone`() async throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = ModelContext(container)
        context.insert(makeMovie(id: "in-flight", status: .downloading))
        try context.save()

        await DownloadManager.recoverInterruptedDownloads(
            liveIDs: ["in-flight"], directory: directory, container: container
        )

        let movie = try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.downloadStatus == .downloading)
    }

    @Test
    func `already-completed downloads are never revisited`() async throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = ModelContext(container)
        let done = makeMovie(id: "done", status: .completed)
        done.localFileURL = "/some/path/done.mp4"
        context.insert(done)
        try context.save()

        await DownloadManager.recoverInterruptedDownloads(
            liveIDs: [], directory: directory, container: container
        )

        let movie = try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.downloadStatus == .completed)
        #expect(movie.localFileURL == "/some/path/done.mp4")
    }
}

@Suite("Downloaded file resolution", .serialized)
struct DownloadedFileResolutionTests {
    /// Writes a file into the real downloads directory, as a finished download would.
    private func plantDownload(named filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: DownloadStorage.directory, withIntermediateDirectories: true)
        let file = DownloadStorage.directory.appendingPathComponent(filename)
        try Data("video".utf8).write(to: file)
        return file
    }

    @Test
    func `a stored filename resolves into the downloads directory`() throws {
        let filename = "resolve-\(UUID().uuidString).mp4"
        let file = try plantDownload(named: filename)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(DownloadStorage.file(forStored: filename)?.path == file.path)
    }

    @Test
    func `a legacy absolute path from a moved container still resolves`() throws {
        // iOS moves the data container to a new UUID on every app update, so a
        // path stored by an older build points into a container that no longer
        // exists, while the file itself sits in the current one.
        let filename = "legacy-\(UUID().uuidString).mp4"
        let file = try plantDownload(named: filename)
        defer { try? FileManager.default.removeItem(at: file) }
        let stale = "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Documents/Downloads/\(filename)"

        #expect(DownloadStorage.file(forStored: stale)?.path == file.path)
    }

    @Test
    func `nothing resolves when the file is gone`() {
        #expect(DownloadStorage.file(forStored: nil) == nil)
        #expect(DownloadStorage.file(forStored: "") == nil)
        #expect(DownloadStorage.file(forStored: "missing-\(UUID().uuidString).mp4") == nil)
    }

    @Test
    func `a completed movie with a stale path plays the local file, not the stream`() throws {
        let filename = "offline-\(UUID().uuidString).mp4"
        let file = try plantDownload(named: filename)
        defer { try? FileManager.default.removeItem(at: file) }

        let playlist = Playlist(name: "P", serverURL: "http://provider.example:8080", username: "u", password: "p")
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, name: "Offline")
        movie.downloadStatus = .completed
        movie.localFileURL = "/var/mobile/Containers/Data/Application/OLD/Documents/Downloads/\(filename)"

        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))
        #expect(media.url.isFileURL)
        #expect(media.url.path == file.path)

        // Not completed: the stream, even though a file with that name exists.
        movie.downloadStatus = .downloading
        #expect(movie.downloadedFile == nil)
    }
}
