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
        #expect(movie.localFileURL == file.path)
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
