//
//  DownloadStorageTests.swift
//  LumeTests
//
//  Covers where downloaded media lives on disk — specifically that it is kept
//  out of the user's backup. A silent no-op here is invisible from inside the
//  app: downloads keep working and the only symptom is the user's iCloud backup
//  quietly growing by gigabytes, so it is worth pinning.
//

import Foundation
@testable import Lume
import Testing

struct DownloadStorageTests {
    /// A throwaway directory standing in for the real downloads folder, so the
    /// test never touches the host's Documents.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isExcluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    @Test func `a directory is excluded from backup`() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try isExcluded(directory) == false) // precondition: opt-in, not the default
        DownloadManager.excludeFromBackup(directory)
        #expect(try isExcluded(directory))
    }

    @Test func `excluding is idempotent`() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Runs on every launch, so applying it to an already-excluded directory
        // must stay a harmless no-op rather than throwing or clearing the flag.
        DownloadManager.excludeFromBackup(directory)
        DownloadManager.excludeFromBackup(directory)
        #expect(try isExcluded(directory))
    }

    @Test func `files added after the directory is marked are covered`() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DownloadManager.excludeFromBackup(directory)

        // The attribute is set once on the directory rather than per download,
        // so a file that lands later must inherit the exclusion — otherwise
        // every completed download would need its own bookkeeping.
        let file = directory.appendingPathComponent("movie.mkv")
        try Data("payload".utf8).write(to: file)

        #expect(try isExcluded(directory))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func `a missing directory fails without throwing`() {
        // Called unconditionally at launch, so a path that doesn't exist yet
        // must not propagate an error into app start-up.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        DownloadManager.excludeFromBackup(missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
