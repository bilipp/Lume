//
//  ImagePipeline.swift
//  Lume
//
//  The loader behind `CachedAsyncImage`. Responsibilities:
//
//  • Coalesce duplicate in-flight requests for the same image so a grid that
//    asks for the same poster from ten cells only downloads it once.
//  • Cancel a coalesced load once its last subscriber is gone, so flicking
//    through a big grid doesn't queue the posters the user is actually looking
//    at behind hundreds of cells that scrolled past seconds ago.
//  • Retry transient network failures (timeouts, dropped connections, 5xx, 429)
//    with backoff — the single biggest reason images "fail to load" today is
//    that `AsyncImage` treats the first blip as permanent.
//  • Remember URLs that just failed, so a dead poster isn't re-requested (and
//    re-retried, with backoff) every single time its cell scrolls back in.
//  • Serve from the memory cache, then the disk cache, then the network.
//  • Offload decode/downsample work to detached tasks so loads run in parallel
//    instead of serializing on the actor.
//
//  Why an actor: it owns only the in-flight table and the negative cache, which
//  need synchronized access. The heavy lifting (IO + decode) happens in detached
//  tasks, so the actor never becomes a bottleneck.
//

import Foundation
import SwiftUI

actor ImagePipeline {
    nonisolated static let shared = ImagePipeline()

    /// Dedicated session with conservative timeouts. We do our own disk caching,
    /// so `URLCache` is disabled to avoid double-storing bytes.
    private let session: URLSession

    /// One shared load plus the subscribers currently waiting on it.
    private struct InFlightLoad {
        let task: Task<PlatformImage, Error>
        /// Tokens of the live `image(for:)` callers awaiting this load. Prefetch
        /// deliberately holds no token: warming is allowed to run to completion on
        /// its own, but it must never keep a load alive once the last visible cell
        /// has scrolled away.
        var waiters: Set<UInt64>
    }

    /// In-flight loads keyed by the memory-cache key (URL + target size), so two
    /// callers wanting the same image at the same size share one task.
    private var inFlight: [String: InFlightLoad] = [:]

    /// Monotonic ids handed out to subscribers so a release can only ever retire
    /// its own subscription. A cancelled load fires both the cancellation handler
    /// and the normal completion path, and a blind counter would then decrement
    /// twice — cancelling a load a *different* cell is still waiting for.
    private var lastWaiterToken: UInt64 = 0

    /// Negative cache: the earliest time a URL that just failed may be asked for
    /// again. Without it a dead poster URL is re-fetched on every scroll pass, and
    /// for the retryable statuses pays ~2.8 s of backoff before failing again.
    private var retryAfter: [String: Date] = [:]

    private let maxRetries = 3

    /// A URL that answers 4xx, or with bytes we can't decode, is not going to start
    /// working during a browse session. Five minutes keeps it out of the whole
    /// session while still letting a re-uploaded poster appear without a relaunch.
    private let deadURLRetryDelay: TimeInterval = 300

    /// Offline / timed-out / 5xx loads get seconds, not minutes: the user may be in
    /// a lift, and walking back into Wi-Fi must not leave every URL they scrolled
    /// past frozen out. Ten seconds is enough to absorb one flick through a grid.
    private let transientRetryDelay: TimeInterval = 10

    /// Ceiling on remembered failures — a 179k-title catalog has no shortage of dead
    /// artwork, and this table must never become the thing that grows.
    private let maxRememberedFailures = 512

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

    /// `URLSession`'s async API reports a cancelled request as `URLError.cancelled`
    /// rather than `CancellationError`, so anything that has to tell "the caller
    /// went away" apart from "this image is broken" must recognise both shapes.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Returns a decoded image for `url`, downsampled to `maxPixelSize` (longest
    /// edge in pixels) when provided. Throws on permanent failure.
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> PlatformImage {
        let key = Self.memoryKey(url, maxPixelSize: maxPixelSize)

        if let cached = ImageMemoryCache.shared.image(for: key) {
            return cached
        }

        if isFrozenOut(url) {
            throw ImagePipelineError.recentlyFailed
        }

        let token = makeWaiterToken()
        let task = startOrJoin(key: key, url: url, maxPixelSize: maxPixelSize, waiter: token, priority: .userInitiated)

        // Awaiting another task's value is not a cancellation point, so before this
        // handler a scrolled-away cell left its download running to completion:
        // flicking through a grid buried the posters actually on screen behind
        // hundreds of stale ones, which is why they stayed grey for seconds.
        // Dropping the token cancels the shared load once nobody is left waiting.
        return try await withTaskCancellationHandler {
            defer { release(waiter: token, key: key) }
            return try await task.value
        } onCancel: {
            Task { await self.release(waiter: token, key: key) }
        }
    }

    /// Warms the cache for upcoming images (e.g. neighbouring hero slides). Fire
    /// and forget — failures are ignored.
    func prefetch(_ urls: [URL], maxPixelSize: CGFloat?) {
        for url in urls {
            let key = Self.memoryKey(url, maxPixelSize: maxPixelSize)
            guard ImageMemoryCache.shared.image(for: key) == nil,
                  inFlight[key] == nil,
                  !isFrozenOut(url) else { continue }
            _ = startOrJoin(key: key, url: url, maxPixelSize: maxPixelSize, waiter: nil, priority: .utility)
        }
    }

    /// Forgets every remembered failure. Clearing the image caches is the user's
    /// "artwork is broken, try again" button, so it has to lift the freeze-out too —
    /// otherwise posters that failed a minute earlier stay blank right after it.
    func forgetFailures() {
        retryAfter.removeAll()
    }

    // MARK: - In-flight table

    /// Joins the existing load for `key`, or starts one. `waiter` is `nil` for
    /// prefetches, which start a load but never hold it open.
    private func startOrJoin(
        key: String,
        url: URL,
        maxPixelSize: CGFloat?,
        waiter: UInt64?,
        priority: TaskPriority
    ) -> Task<PlatformImage, Error> {
        if var entry = inFlight[key] {
            if let waiter {
                entry.waiters.insert(waiter)
                inFlight[key] = entry
            }
            return entry.task
        }

        let task = Task.detached(priority: priority) { [maxRetries] in
            try await Self.load(url: url, maxPixelSize: maxPixelSize, key: key, retries: maxRetries)
        }
        var waiters: Set<UInt64> = []
        if let waiter { waiters.insert(waiter) }
        inFlight[key] = InFlightLoad(task: task, waiters: waiters)
        Task { await self.retire(key: key, url: url, task: task) }
        return task
    }

    /// Drops one subscription and, when it was the last, cancels the shared load.
    /// Removing the row *before* cancelling matters: a cell that scrolls straight
    /// back in must start a fresh load instead of joining a task already unwinding.
    private func release(waiter token: UInt64, key: String) {
        guard var entry = inFlight[key], entry.waiters.remove(token) != nil else { return }
        guard entry.waiters.isEmpty else {
            inFlight[key] = entry
            return
        }
        inFlight[key] = nil
        entry.task.cancel()
    }

    /// Records the outcome once a load settles and retires its row unless a newer
    /// load has already replaced it.
    private func retire(key: String, url: URL, task: Task<PlatformImage, Error>) async {
        do {
            _ = try await task.value
            retryAfter[url.absoluteString] = nil
        } catch {
            noteFailure(error, for: url)
        }
        if inFlight[key]?.task == task {
            inFlight[key] = nil
        }
    }

    private func makeWaiterToken() -> UInt64 {
        lastWaiterToken &+= 1
        return lastWaiterToken
    }

    // MARK: - Negative cache

    /// True while `url` is inside its retry window. Expired entries are dropped on
    /// the way past so the table drains without a timer.
    private func isFrozenOut(_ url: URL) -> Bool {
        guard let deadline = retryAfter[url.absoluteString] else { return false }
        guard deadline > .now else {
            retryAfter[url.absoluteString] = nil
            return false
        }
        return true
    }

    /// Remembers a failed URL so the next hundred cells asking for it don't each pay
    /// a round trip to rediscover the same dead poster. A cancellation is not a
    /// failure — the image was never given a chance — and transient errors get the
    /// short window so an offline moment doesn't blank the catalog for minutes.
    private func noteFailure(_ error: Error, for url: URL) {
        guard !Self.isCancellation(error) else { return }
        let delay = Self.isTransientFailure(error) ? transientRetryDelay : deadURLRetryDelay
        retryAfter[url.absoluteString] = Date.now.addingTimeInterval(delay)
        pruneFailuresIfNeeded()
    }

    private func pruneFailuresIfNeeded() {
        guard retryAfter.count > maxRememberedFailures else { return }
        let now = Date.now
        retryAfter = retryAfter.filter { $0.value > now }
        guard retryAfter.count > maxRememberedFailures else { return }
        // Still over the cap even after dropping the expired entries: keep the
        // freshest half, which is the part a scrolling user is about to hit again.
        let freshest = retryAfter.sorted { $0.value > $1.value }.prefix(maxRememberedFailures / 2)
        retryAfter = Dictionary(uniqueKeysWithValues: freshest.map { ($0.key, $0.value) })
    }

    /// Failures that say "not now" rather than "not ever": everything `fetch` already
    /// retries, plus the URL errors it treats as blips.
    private nonisolated static func isTransientFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return isTransient(urlError)
        }
        if let pipelineError = error as? ImagePipelineError, case let .httpStatus(code) = pipelineError {
            return code == 429 || (500 ... 599).contains(code)
        }
        return false
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

        // The decode below is the expensive part; skip it for a subscriber that has
        // already gone away rather than burning a core on pixels nobody will draw.
        try Task.checkCancellation()

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
    /// This URL failed moments ago and is still inside its retry window. Thrown
    /// without touching the network so a scroll pass over broken artwork is free.
    case recentlyFailed
}
