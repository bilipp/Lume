//
//  SportarrIndexTests.swift
//  LumeTests
//
//  Derived metadata can be discarded. Catalog files cannot: outages preserve
//  answers and misses back off rather than becoming a repeated lookup loop.
//

import Foundation
@testable import Lume
import Testing

struct SportarrIndexTests {
    private let now = Date(timeIntervalSince1970: 1_794_765_600)

    private func file(fingerprint: String = "first", title: String = "Game") -> SportarrImportFile {
        SportarrImportFile(
            catalogID: "fixture-movie", kind: .movie, eventID: "ev-123456", title: title, date: nil,
            seriesID: nil, seriesTitle: nil, leagueID: nil, libraryTitle: "NFL", seasonNumber: 2026,
            fileName: "Game.mkv", fingerprint: fingerprint
        )
    }

    private func answer(id: String = "ev-123456") throws -> SportarrEpisode {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "home_team": "Lions", "away_team": "Patriots"])
        return try JSONDecoder().decode(SportarrEpisode.self, from: data)
    }

    @Test func `resolved files stay resolved across scans and display renames`() throws {
        var record = SportarrIndexedFile(file: file())
        try record.apply(.found(answer()), now: now)
        #expect(!record.needsLookup(now: now.addingTimeInterval(365 * 86400)))
        record.update(file(title: "Renamed Game"))
        #expect(record.file.title == "Renamed Game")
        #expect(!record.needsLookup(now: now))
        record.update(file(fingerprint: "replacement"))
        #expect(record.needsLookup(now: now))
        #expect(record.metadata == nil)
    }

    @Test func `outage and disabled results retain the complete previous answer`() throws {
        var record = SportarrIndexedFile(file: file())
        try record.apply(.found(answer()), now: now)
        let before = record
        record.apply(.unavailable, now: now.addingTimeInterval(3600))
        #expect(record == before)
        record.apply(.disabled, now: now.addingTimeInterval(7200))
        #expect(record == before)
    }

    @Test func `missing answers grow to a weekly retry ceiling`() {
        var record = SportarrIndexedFile(file: file())
        record.apply(.missing, now: now)
        #expect(!record.needsLookup(now: now.addingTimeInterval(3599)))
        #expect(record.needsLookup(now: now.addingTimeInterval(3600)))
        for _ in 0 ..< 20 {
            record.apply(.missing, now: now)
        }
        #expect(record.nextLookupAt == now.addingTimeInterval(7 * 86400))
    }

    @Test func `a response for another identity cannot replace the file`() throws {
        var record = SportarrIndexedFile(file: file())
        try record.apply(.found(answer(id: "ev-654321")), now: now)
        #expect(record.resolution == .rejected)
        #expect(record.metadata == nil)
        #expect(record.file.eventID == "ev-123456")
    }

    @Test func `signed handles do not alter file identity or enter the persisted index`() throws {
        let first = SportarrImportFile.fingerprint(path: "https://private.test/Game.mkv?token=one", created: "date", duration: 100, eventID: "ev-123456")
        let second = SportarrImportFile.fingerprint(path: "https://private.test/Game.mkv?token=two", created: "date", duration: 100, eventID: "ev-123456")
        #expect(first == second)
        let record = SportarrIndexedFile(file: file(fingerprint: first))
        let text = try #require(String(data: JSONEncoder().encode(record), encoding: .utf8))
        #expect(!text.contains("private.test"))
        #expect(!text.contains("token="))
    }

    @Test func `per playlist disk state round trips and corruption is disposable`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SportarrIndexStore(directory: directory)
        let id = UUID()
        var index = SportarrPlaylistIndex(playlistID: id)
        index.files["fixture-movie"] = SportarrIndexedFile(file: file())
        try await store.save(index)
        #expect(await store.load(playlistID: id).files.count == 1)
        let url = directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
        try Data("invalid cache".utf8).write(to: url)
        #expect(await store.load(playlistID: id).files.isEmpty)
    }
}
