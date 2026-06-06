//
//  ImagePipeline.swift
//  Lume
//
//  The loader behind `CachedAsyncImage`. Responsibilities:
//
//  • Coalesce duplicate in-flight requests for the same image so a grid that
//    asks for the same poster from ten cells only downloads it once.
//  • Retry transient network failures (timeouts, dropped connections, 5xx, 429)
//    with backoff — the single biggest reason images "fail to load" today is
//    that `AsyncImage` treats the first blip as permanent.
//  • Serve from the memory cache, then the disk cache, then the network.
//  • Offload decode/downsample work to detached tasks so loads run in parallel
//    instead of serializing on the actor.
//
//  Why an actor: it owns only the in-flight table, which needs synchronized
//  access. The heavy lifting (IO + decode) happens in detached tasks, so the
//  actor never becomes a bottleneck.
//

import Foundation
import SwiftUI

actor ImagePipeline {
    nonisolated static let shared = ImagePipeline()

    /// Dedicated session with conservative timeouts. We do our own disk caching,
    /// so `URLCache` is disabled to avoid double-storing bytes.
    private let session: URLSession

    /// In-flight loads keyed by the memory-cache key (URL + target size), so two
    /// callers wanting the same image at the same size share one task.
    private var inFlight: [String: Task<PlatformImage, Error>] = [:]

    private let maxRetries = 3

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Builds the memory-cache key. Disk is keyed by URL alone (original bytes);
    /// memory is keyed by URL + size (decoded result depends on the target size).
    nonisolated static func memoryKey(_ url: URL, maxPixelSize: CGFloat?) -> String {
        if let maxPixelSize {
            "\(url.absoluteString)|\(Int(maxPixelSize))"
        } else {
            "\(url.absoluteString)|full"
        }
    }

    /// Synchronous peek used by `CachedAsyncImage` to render cache hits with no
    /// placeholder flash on the very first frame.
    nonisolated static func cachedImage(for url: URL, maxPixelSize: CGFloat?) -> PlatformImage? {
        ImageMemoryCache.shared.image(for: memoryKey(url, maxPixelSize: maxPixelSize))
    }

    /// Returns a decoded image for `url`, downsampled to `maxPixelSize` (longest
    /// edge in pixels) when provided. Throws on permanent failure.
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> PlatformImage {
        let key = Self.memoryKey(url, maxPixelSize: maxPixelSize)

        if let cached = ImageMemoryCache.shared.image(for: key) {
            return cached
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task.detached(priority: .userInitiated) { [maxRetries] in
            try await Self.load(url: url, maxPixelSize: maxPixelSize, key: key, retries: maxRetries)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Warms the cache for upcoming images (e.g. neighbouring hero slides). Fire
    /// and forget — failures are ignored.
    func prefetch(_ urls: [URL], maxPixelSize: CGFloat?) {
        for url in urls {
            let key = Self.memoryKey(url, maxPixelSize: maxPixelSize)
            guard ImageMemoryCache.shared.image(for: key) == nil, inFlight[key] == nil else { continue }
            let task = Task.detached(priority: .utility) { [maxRetries] in
                try await Self.load(url: url, maxPixelSize: maxPixelSize, key: key, retries: maxRetries)
            }
            inFlight[key] = task
            Task { await self.clearInFlight(key, when: task) }
        }
    }

    private func clearInFlight(_ key: String, when task: Task<PlatformImage, Error>) async {
        _ = try? await task.value
        inFlight[key] = nil
    }

    // MARK: - Loading (runs off-actor)

    private nonisolated static func load(url: URL, maxPixelSize: CGFloat?, key: String, retries: Int) async throws -> PlatformImage {
        // Disk holds the original bytes keyed by URL; reuse across target sizes.
        let diskKey = url.absoluteString
        if let data = ImageDiskCache.shared.data(for: diskKey),
           let image = ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
        {
            ImageMemoryCache.shared.insert(image, for: key)
            return image
        }

        let data = try await fetch(url: url, retries: retries)
        ImageDiskCache.shared.store(data, for: diskKey)

        guard let image = ImageDecoder.decode(data, maxPixelSize: maxPixelSize) else {
            throw ImagePipelineError.decodingFailed
        }
        ImageMemoryCache.shared.insert(image, for: key)
        return image
    }

    private nonisolated static func fetch(url: URL, retries: Int) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await ImagePipeline.shared.session.data(from: url)
                if let http = response as? HTTPURLResponse {
                    if (200 ... 299).contains(http.statusCode) {
                        return data
                    }
                    // Retry server overload / rate limiting; fail fast on 4xx.
                    if http.statusCode == 429 || (500 ... 599).contains(http.statusCode),
                       attempt < retries
                    {
                        try await backoff(attempt)
                        attempt += 1
                        continue
                    }
                    throw ImagePipelineError.httpStatus(http.statusCode)
                }
                return data
            } catch let error as URLError where Self.isTransient(error) && attempt < retries {
                try await backoff(attempt)
                attempt += 1
            }
        }
    }

    private nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .badServerResponse:
            true
        default:
            false
        }
    }

    /// Exponential backoff: ~0.4s, 0.8s, 1.6s.
    private nonisolated static func backoff(_ attempt: Int) async throws {
        let nanoseconds = UInt64(0.4 * pow(2.0, Double(attempt)) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

enum ImagePipelineError: Error {
    case decodingFailed
    case httpStatus(Int)
}
