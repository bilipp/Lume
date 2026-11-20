//
//  TitleGroupBridgeBenchmarks.swift
//  LumePerformanceTests
//
//  The title-key bridge at provider scale. `M3UColdImportBenchmarks` imports
//  an m3u-only catalog, where no row carries a tmdbId, so `hasBridgeWork` is
//  false and `TitleGroupBridge` never runs there.
//
//  Each pass cold-imports the same provider-shaped m3u playlist as
//  `M3UColdImportBenchmarks` (unmeasured), then cold-imports an Xtream
//  playlist into the same on-disk store whose rows carry a tmdb id for every
//  distinct title the m3u import produced. That Xtream phase is what is
//  measured: every m3u row of a title adopts the Xtream row's `tmdb:` key.
//
//  Movies and series are separate tests because `XCTOSSignpostMetric` keeps
//  only the first interval of a name per iteration, and each phase runs the
//  bridge once.
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

final class TitleGroupBridgeBenchmarks: XCTestCase {
    private static let entryCount = 600_000
    private static let showCount = entryCount / 40

    private static let host = "bridge-perf.invalid"

    private var scratch: URL!
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try PerfFixtures.makeScratchDirectory()
        fixtureURL = try PerfFixtures.writeM3UProviderShape(
            entryCount: Self.entryCount, showCount: Self.showCount, to: scratch
        )
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        fixtureURL = nil
        BridgeStubURLProtocol.reset()
        try super.tearDownWithError()
    }

    // MARK: - Benchmarks

    /// Xtream movies with a tmdb id for every m3u movie title.
    func testXtreamMoviesBridgeOntoM3UCatalog() throws {
        try measureXtreamPhase(.movies)
    }

    /// Xtream series with a tmdb id for every m3u show title.
    func testXtreamSeriesBridgeOntoM3UCatalog() throws {
        try measureXtreamPhase(.series)
    }

    // MARK: - Harness

    private enum Phase {
        case movies
        case series
    }

    private func measureXtreamPhase(_ phase: Phase) throws {
        let fixtureURL = try XCTUnwrap(fixtureURL)

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 1
        measure(metrics: Self.metrics, options: options) {
            guard let store = try? PerfStore.makeOnDiskContainer() else {
                XCTFail("could not create the on-disk store")
                return
            }
            defer { PerfStore.destroy(directory: store.directory) }

            guard let m3uId = try? seedM3UPlaylist(fileURL: fixtureURL, container: store.container) else {
                XCTFail("could not seed the m3u playlist row")
                return
            }
            clearM3UDeviceLocalState(playlistId: m3uId)
            defer { clearM3UDeviceLocalState(playlistId: m3uId) }

            let m3uManager = ContentSyncManager(modelContainer: store.container)
            if let error = syncPlaylistSynchronously(manager: m3uManager, playlistId: m3uId, container: store.container).error {
                XCTFail("m3u sync failed: \(error)")
                return
            }

            guard let xtreamId = try? seedXtreamPlaylist(container: store.container) else {
                XCTFail("could not seed the Xtream playlist row")
                return
            }
            defer { clearXtreamDeviceLocalState(playlistId: xtreamId) }
            let titleCount = registerXtreamPayloads(for: phase, from: store.container)
            XCTAssertGreaterThan(titleCount, 0, "the m3u import left no titles to carry")

            let xtreamManager = ContentSyncManager(
                modelContainer: store.container,
                xtreamClient: XtreamClient(urlSession: BridgeStubURLProtocol.makeSession())
            )
            startMeasuring()
            let outcome = runXtreamPhase(phase, manager: xtreamManager, playlistId: xtreamId, container: store.container)
            stopMeasuring()

            if let error = outcome.error {
                XCTFail("Xtream sync failed: \(error)")
            }
            assertEveryTitleRowAdopted(phase, container: store.container)
        }
    }

    private func seedXtreamPlaylist(container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let playlist = Playlist(name: "Perf Xtream", serverURL: "http://\(Self.host)", username: "u", password: "p")
        context.insert(playlist)
        try context.save()
        clearXtreamDeviceLocalState(playlistId: playlist.id)
        return playlist.id
    }

    private func clearXtreamDeviceLocalState(playlistId: UUID) {
        XtreamDigestStore.removeAll(playlistId: playlistId)
        SweepSkipDefaults.removeAll(playlistId: playlistId)
        TitleGroupPrimaries.Deferred.clear(playlistId: playlistId)
    }

    /// One Xtream row per distinct m3u title, each with its own tmdb id, so
    /// every title has exactly one carrier and every m3u row of it adopts.
    /// Returns the number of titles.
    private func registerXtreamPayloads(for phase: Phase, from container: ModelContainer) -> Int {
        let context = ModelContext(container)
        let names: [String]
        switch phase {
        case .movies:
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.titleMatchKey != nil })
            descriptor.propertiesToFetch = [\.name, \.titleMatchKey]
            names = Self.oneNamePerTitle(((try? context.fetch(descriptor)) ?? []).map { ($0.name, $0.titleMatchKey) })
        case .series:
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.titleMatchKey != nil })
            descriptor.propertiesToFetch = [\.name, \.titleMatchKey]
            names = Self.oneNamePerTitle(((try? context.fetch(descriptor)) ?? []).map { ($0.name, $0.titleMatchKey) })
        }

        let categoryCount = 60
        let categories = (0 ..< categoryCount).map { ["category_id": "\(9000 + $0)", "category_name": "Perf \($0)", "parent_id": 0] as [String: Any] }
        let rows: [[String: Any]] = names.enumerated().map { index, name in
            var row: [String: Any] = [
                "num": index + 1,
                "name": name,
                "category_id": "\(9000 + index % categoryCount)",
                "tmdb": "\(5_000_000 + index)"
            ]
            switch phase {
            case .movies:
                row["stream_type"] = "movie"
                row["stream_id"] = 3_000_000 + index
                row["container_extension"] = "mkv"
            case .series:
                row["series_id"] = 4_000_000 + index
            }
            return row
        }

        let empty = Data("[]".utf8)
        let categoryData = (try? JSONSerialization.data(withJSONObject: categories)) ?? empty
        let rowData = (try? JSONSerialization.data(withJSONObject: rows)) ?? empty
        var payloads = [
            "get_vod_categories": empty,
            "get_series_categories": empty,
            "get_live_categories": empty
        ]
        switch phase {
        case .movies:
            payloads["get_vod_categories"] = categoryData
            payloads["get_vod_streams"] = rowData
        case .series:
            payloads["get_series_categories"] = categoryData
            payloads["get_series"] = rowData
        }
        BridgeStubURLProtocol.payloads = payloads
        return names.count
    }

    private static func oneNamePerTitle(_ rows: [(String, String?)]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for (name, matchKey) in rows {
            guard let matchKey, seen.insert(matchKey).inserted else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    /// Categories, then the one content phase — not `syncPlaylist`, whose
    /// auth call, live phase and provider phase spacing are not the bridge.
    private func runXtreamPhase(
        _ phase: Phase,
        manager: ContentSyncManager,
        playlistId: UUID,
        container: ModelContainer
    ) -> PerfSyncOutcome {
        let outcome = PerfSyncOutcome()
        let finished = expectation(description: "Xtream phase")
        Task.detached {
            do {
                let context = ModelContext(container)
                guard let playlist = try context.fetch(
                    FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
                ).first else {
                    throw SyncError.playlistNotFound
                }
                try await manager.syncAllCategories(for: playlist, playlistId: playlistId)
                switch phase {
                case .movies: try await manager.syncMovies(for: playlist, playlistId: playlistId)
                case .series: try await manager.syncSeries(for: playlist, playlistId: playlistId)
                }
            } catch {
                outcome.error = error
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3600)
        return outcome
    }

    /// A pass where nothing adopted measured a bridge that did no work.
    private func assertEveryTitleRowAdopted(_ phase: Phase, container: ModelContainer) {
        let context = ModelContext(container)
        let titleKeyed: Int
        let adopted: Int
        switch phase {
        case .movies:
            titleKeyed = (try? context.fetchCount(TitleGroupPrimaries.BridgeQueries.movies.titleKeyed)) ?? 0
            adopted = (try? context.fetchCount(TitleGroupPrimaries.BridgeQueries.movies.anyAdopted)) ?? 0
        case .series:
            titleKeyed = (try? context.fetchCount(TitleGroupPrimaries.BridgeQueries.series.titleKeyed)) ?? 0
            adopted = (try? context.fetchCount(TitleGroupPrimaries.BridgeQueries.series.anyAdopted)) ?? 0
        }
        XCTAssertGreaterThan(titleKeyed, 0, "no tmdbId-less rows to bridge")
        XCTAssertEqual(adopted, titleKeyed, "every title-keyed row has exactly one carrier and should have adopted")
    }

    // MARK: - Metrics

    private static var metrics: [XCTMetric] {
        var metrics: [XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()]
        metrics.append(contentsOf: signposts.map(M3UColdImportBenchmarks.signpostMetric))
        return metrics
    }

    /// All one interval per pass: each test runs a single content phase.
    private static let signposts: [PerfSignpost] = [
        .titleGroupBridge,
        .syncCategories,
        .syncMovies,
        .upsertMovies,
        .pruneMovies,
        .syncSeries,
        .upsertSeries,
        .pruneSeries
    ]
}

// MARK: - Stub transport

/// Answers every Xtream request from `payloads`, keyed by its `action`.
private final nonisolated class BridgeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storage: [String: Data] = [:]

    static var payloads: [String: Data] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    static func reset() {
        payloads = [:]
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "action" }?.value ?? ""
        let body = Self.payloads[action]
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
