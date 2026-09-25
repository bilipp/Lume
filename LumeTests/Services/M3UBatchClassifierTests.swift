//
//  M3UBatchClassifierTests.swift
//  LumeTests
//
//  The m3u import classifies each batch on the producer side, off the writer's
//  critical path. `num` — the "Playlist order" sort key — is assigned from the
//  order these three arrays come out in, on first insert, so a split that
//  reordered anything would silently scramble every playlist-ordered screen.
//

import Foundation
@testable import Lume
import Testing

private func makeEntries(_ count: Int) -> [M3UEntry] {
    (0 ..< count).map { index in
        switch index % 3 {
        case 0:
            M3UEntry(
                name: "Channel \(index)", url: "http://example.com/live/\(index).ts",
                tvgId: "chan.\(index)", logo: nil, group: "News", type: nil
            )
        case 1:
            M3UEntry(
                name: "Movie \(index)", url: "http://example.com/movie/\(index).mp4",
                tvgId: nil, logo: nil, group: "Films", type: nil
            )
        default:
            M3UEntry(
                name: "Show \(index % 17) S0\(index % 9)E\(index) Chapter",
                url: "http://example.com/series/\(index).mkv",
                tvgId: nil, logo: nil, group: "Shows", type: nil
            )
        }
    }
}

struct M3UBatchClassifierTests {
    @Test func `every entry lands in exactly one bucket, in file order`() {
        let entries = makeEntries(2000)
        let batch = M3UBatchClassifier.classify(entries)

        #expect(batch.live.count + batch.movies.count + batch.episodes.count == entries.count)
        #expect(batch.live.map(\.url) == entries.indices.filter { $0 % 3 == 0 }.map { entries[$0].url })
        #expect(batch.movies.map(\.url) == entries.indices.filter { $0 % 3 == 1 }.map { entries[$0].url })
        #expect(batch.episodes.map(\.0.url) == entries.indices.filter { $0 % 3 == 2 }.map { entries[$0].url })
    }

    /// The season/episode split has to survive the move off the writer — the
    /// importer reads the episode title from the very match that classified it.
    @Test func `episode metadata matches the classifier`() {
        let batch = M3UBatchClassifier.classify(makeEntries(300))

        for (entry, series, season, episode, title) in batch.episodes {
            let reference = M3UClassifier.classification(of: entry)
            #expect(reference.kind == .episode(series: series, season: season, episode: episode))
            #expect(reference.episodeTitle == title)
        }
        #expect(!batch.episodes.isEmpty)
    }

    @Test func `an empty batch classifies to nothing`() {
        let batch = M3UBatchClassifier.classify([])
        #expect(batch.live.isEmpty)
        #expect(batch.movies.isEmpty)
        #expect(batch.episodes.isEmpty)
    }
}

// MARK: - Equivalence with the per-entry classifier

/// Comparable projection of a split — `M3UEntry` and the episode tuple are not
/// `Equatable`, and the URL identifies an entry uniquely inside a batch.
private func fingerprint(_ batch: M3UClassifiedBatch) -> (live: [String], movies: [String], episodes: [String]) {
    (
        batch.live.map(\.url),
        batch.movies.map(\.url),
        batch.episodes.map { "\($0.0.url)|\($0.series)|\($0.season)|\($0.episode)|\($0.title)" }
    )
}

/// The classifier's own awkward cases as they turn up interleaved in a provider
/// file: `M3UClassifierTests` pins what each classifies *as*, so what is at
/// stake here is that the batch split reaches the same verdict for every one of
/// them and leaves them in file order.
private let edgeCaseEntries: [M3UEntry] = {
    func entry(_ name: String, _ url: String, type: String? = nil) -> M3UEntry {
        M3UEntry(name: name, url: url, tvgId: nil, logo: nil, group: "Mixed", type: type)
    }
    return [
        entry("Bare Endpoint", "http://example.com/12345"),
        entry("Transport Stream", "http://example.com/hls/chan.ts"),
        entry("HLS Manifest", "http://example.com/hls/chan.m3u8"),
        entry("Index Endpoint", "http://cdn.example.com:9999/channel/n36074338/index.mpeg?q=abc"),
        entry("Index Endpoint VOD", "http://cdn.example.com:9999/channel/n36074339/index.mpeg?q=abc", type: "video"),
        entry("Live Path", "http://example.com/live/123/index.mpg"),
        entry("Stream Path", "http://example.com/stream/12345"),
        entry("Film", "http://example.com/vod/film.mp4"),
        entry("Movie Path", "http://example.com/movie/user/pass/99.avi"),
        entry("Some Special", "http://example.com/series/u/p/7.mp4"),
        entry("Foo TV 640x480", "http://example.com/foo.ts"),
        entry("Bar 640x480", "http://example.com/bar.mp4"),
        entry("Breaking Bad S05E16 Felina", "http://example.com/series/u/p/1.mp4"),
        entry("The Wire - S01 E03 - The Buys", "http://example.com/x.mkv"),
        entry("Dark 2x05", "http://example.com/dark.mp4"),
        entry("S01E01 Pilot", "http://example.com/p.mp4"),
        entry("Dark S02E05", "http://example.com/channel/x/index.mpeg", type: "video")
    ]
}()

/// Every entry landed in the bucket `M3UClassifier.classification(of:)` names
/// for it, each bucket kept file order, and nothing was dropped or duplicated —
/// checked against the per-entry classifier itself, which is the answer the
/// batch split owes whatever it does to get through a batch faster.
private func expectSplitMatchesClassifier(_ entries: [M3UEntry]) {
    let batch = M3UBatchClassifier.classify(entries)

    for entry in batch.live {
        #expect(M3UClassifier.classification(of: entry).kind == .live, "\(entry.name) is not live")
    }
    for entry in batch.movies {
        #expect(M3UClassifier.classification(of: entry).kind == .movie, "\(entry.name) is not a movie")
    }
    for (entry, series, season, episode, title) in batch.episodes {
        let classification = M3UClassifier.classification(of: entry)
        #expect(classification.kind == .episode(series: series, season: season, episode: episode))
        #expect(classification.episodeTitle == title)
    }

    // File order, per bucket, and nothing lost between them: an entry's URL is
    // unique inside these fixtures, so its file position identifies it.
    var position: [String: Int] = [:]
    for (index, entry) in entries.enumerated() {
        position[entry.url] = index
    }
    let buckets = [batch.live.map(\.url), batch.movies.map(\.url), batch.episodes.map(\.0.url)]
        .map { $0.compactMap { position[$0] } }
    for bucket in buckets {
        #expect(bucket == bucket.sorted())
    }
    #expect(buckets.flatMap(\.self).sorted() == Array(entries.indices))
}

struct M3UBatchSplitEquivalenceTests {
    @Test func `the classifier's edge cases split exactly as the per-entry classifier does`() {
        expectSplitMatchesClassifier(edgeCaseEntries)

        // Guards against the checks above passing because everything landed in
        // one bucket, or nothing did.
        let batch = M3UBatchClassifier.classify(edgeCaseEntries)
        #expect(!batch.live.isEmpty)
        #expect(!batch.movies.isEmpty)
        #expect(!batch.episodes.isEmpty)
    }

    /// The import hands the producer 2,000 entries at a time, so a batch that
    /// stops short of that would never exercise whatever the classifier does at
    /// scale. This one is over three batches' worth.
    @Test func `a batch several import batches wide stays in file order`() {
        expectSplitMatchesClassifier(makeEntries(6000) + edgeCaseEntries)
    }

    /// Order within each bucket is what `num` — the "Playlist order" sort key —
    /// is assigned from, so an unstable split would scramble the catalog
    /// differently on every import rather than fail outright.
    @Test func `classifying the same batch repeatedly gives the identical split`() {
        let entries = makeEntries(4000) + edgeCaseEntries
        let first = fingerprint(M3UBatchClassifier.classify(entries))

        for _ in 0 ..< 10 {
            let repeated = fingerprint(M3UBatchClassifier.classify(entries))
            #expect(repeated.live == first.live)
            #expect(repeated.movies == first.movies)
            #expect(repeated.episodes == first.episodes)
        }
    }
}
