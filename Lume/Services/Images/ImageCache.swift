//
//  ImageCache.swift
//  Lume
//
//  Two-tier image caching that backs `CachedAsyncImage`:
//
//  • `ImageMemoryCache` keeps *decoded* (and optionally downsampled) images in
//    an `NSCache`, keyed by URL + target size. This is what makes scrolling
//    smooth — once an image is decoded it survives cell reuse, so a poster that
//    scrolls off and back never re-decodes or flashes a placeholder.
//  • `ImageDiskCache` persists the *original* downloaded bytes on disk, keyed by
//    URL only. It survives app launches and, crucially, works regardless of
//    whether the (often flaky IPTV) image host sends sensible cache headers —
//    which `URLCache` alone does not guarantee.
//
//  Decoding/downsampling lives here too so the pipeline can offload it.
//

import CryptoKit
import Foundation
import ImageIO
import OSLog
import SwiftUI

#if canImport(UIKit)
    import UIKit

    typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit

    typealias PlatformImage = NSImage
#endif

extension Image {
    /// Bridges a decoded platform image into a SwiftUI `Image` on either UIKit
    /// (iOS/tvOS/visionOS) or AppKit (macOS).
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
            self.init(uiImage: platformImage)
        #else
            self.init(nsImage: platformImage)
        #endif
    }
}

// MARK: - Memory cache

/// Thread-safe in-memory store of decoded images. `NSCache` evicts under memory
/// pressure on its own, so we only set a generous cost ceiling.
final nonisolated class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        // ~256 MB of decoded pixels; NSCache also purges on memory warnings.
        cache.totalCostLimit = 256 * 1024 * 1024
        #if canImport(UIKit)
            // NSCache evicts under pressure on its own, but silently and only
            // reactively. Observe the explicit warning too so we drop *all* decoded
            // pixels at once and leave a breadcrumb — a suspended app holding 256 MB
            // of posters is a prime jetsam target, which reads to users as the app
            // being slow / reloading after a long time in the background. The disk
            // cache still holds the bytes, so this forces a re-decode, not a
            // re-download. The singleton lives for the whole process, so the observer
            // never needs removing.
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.purge(reason: "memory warning")
            }
        #endif
    }

    func image(for key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: PlatformImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.approximateByteCost)
    }

    func removeAll() {
        cache.removeAllObjects()
        // Clearing the caches is the user's "artwork is broken, try again" button
        // (Settings → Storage). The pipeline's negative cache has to go with them:
        // otherwise the URLs that failed minutes ago stay frozen out and the clear
        // looks like it did nothing for the very posters that prompted it.
        Task { await ImagePipeline.shared.forgetFailures() }
    }

    /// Drops every decoded image and logs why. Called on memory warnings and when
    /// the app backgrounds, to shrink the resident footprint a suspended app keeps.
    /// The disk cache still holds the original bytes, so this only forces a re-decode.
    func purge(reason: String) {
        cache.removeAllObjects()
        Logger.memory.notice("Image memory cache purged (\(reason, privacy: .public))")
    }
}

// MARK: - Disk cache

/// Persists original image bytes in the Caches directory. Reads/writes are
/// synchronous file IO and are always called off the main actor (from the
/// detached load tasks in `ImagePipeline`).
final nonisolated class ImageDiskCache: @unchecked Sendable {
    static let shared = ImageDiskCache()

    /// Original artwork is useful across launches, but it must not grow in
    /// proportion to a provider's entire catalog. 512 MB keeps thousands of
    /// posters (or hundreds of backdrops) warm without becoming an unbounded
    /// second media library.
    static let defaultByteLimit: Int64 = 512 * 1024 * 1024
    /// Image URLs occasionally keep serving different bytes. A hard lifetime
    /// guarantees that even frequently viewed artwork is eventually refreshed.
    static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry {
        let url: URL
        let byteCount: Int64
        let createdAt: Date
        let lastAccessedAt: Date
    }

    struct MaintenanceResult: Equatable {
        let bytesBefore: Int64
        let bytesAfter: Int64
        let expiredFiles: Int
        let evictedFiles: Int
    }

    private let directory: URL
    private let fileManager = FileManager.default
    private let byteLimit: Int64
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let automaticallyMaintains: Bool
    private let initialMaintenanceDelay: Duration

    /// Maintenance is intentionally detached from image delivery. These fields
    /// coalesce a burst of writes into one sweep, while `estimatedByteCount`
    /// lets later writes avoid another directory walk until it is warranted.
    private let maintenanceLock = NSLock()
    private var estimatedByteCount: Int64?
    private var writesSinceReconciliation = 0
    private var maintenanceRunning = false
    private var maintenanceRequested = false
    private let reconciliationWriteInterval = 128

    init(
        directory: URL? = nil,
        byteLimit: Int64 = ImageDiskCache.defaultByteLimit,
        maxAge: TimeInterval = ImageDiskCache.defaultMaxAge,
        automaticallyMaintains: Bool = true,
        initialMaintenanceDelay: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        precondition(byteLimit > 0)
        precondition(maxAge > 0)
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? base.appendingPathComponent("LumeImageCache", isDirectory: true)
        self.byteLimit = byteLimit
        self.maxAge = maxAge
        self.automaticallyMaintains = automaticallyMaintains
        self.initialMaintenanceDelay = initialMaintenanceDelay
        self.now = now
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        scheduleInitialMaintenance()
    }

    /// The on-disk cache directory, exposed so the Storage screen can sum its size.
    var directoryURL: URL {
        directory
    }

    func data(for key: String) -> Data? {
        let url = fileURL(for: key)
        guard let entry = entry(for: url) else { return nil }
        guard now().timeIntervalSince(entry.createdAt) <= maxAge else {
            if remove(entry) { recordRemoval(byteCount: entry.byteCount) }
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Memory hits never reach disk, so touching once per process/use is far
        // less write-heavy than it appears and gives eviction a useful LRU order.
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, for key: String) {
        guard !data.isEmpty, Int64(data.count) <= byteLimit else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        let previousByteCount = entry(for: url)?.byteCount ?? 0
        do {
            try data.write(to: url, options: .atomic)
            let timestamp = now()
            try? fileManager.setAttributes(
                [.creationDate: timestamp, .modificationDate: timestamp],
                ofItemAtPath: url.path
            )
            recordStore(previousByteCount: previousByteCount, byteCount: Int64(data.count))
        } catch {
            Logger.memory.error("Image disk cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        maintenanceLock.lock()
        estimatedByteCount = 0
        writesSinceReconciliation = 0
        if maintenanceRunning { maintenanceRequested = true }
        maintenanceLock.unlock()
    }

    /// Runs the same bounded maintenance used in production. Internal so tests
    /// can verify eviction synchronously without racing an unstructured task.
    @discardableResult
    func performMaintenance() -> MaintenanceResult {
        let entries = cacheEntries()
        let bytesBefore = entries.reduce(into: Int64(0)) { $0 += $1.byteCount }
        var bytesAfter = bytesBefore
        var expiredFiles = 0
        var evictedFiles = 0
        let expirationDate = now().addingTimeInterval(-maxAge)

        var liveEntries: [Entry] = []
        liveEntries.reserveCapacity(entries.count)
        for entry in entries {
            if entry.createdAt < expirationDate, remove(entry) {
                bytesAfter -= entry.byteCount
                expiredFiles += 1
            } else {
                liveEntries.append(entry)
            }
        }

        if bytesAfter > byteLimit {
            // Trim below the ceiling so the next handful of downloads do not
            // immediately trigger another full directory enumeration.
            let targetByteCount = byteLimit * 9 / 10
            for entry in liveEntries.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
                guard bytesAfter > targetByteCount else { break }
                if remove(entry) {
                    bytesAfter -= entry.byteCount
                    evictedFiles += 1
                }
            }
        }

        maintenanceLock.lock()
        estimatedByteCount = max(0, bytesAfter)
        writesSinceReconciliation = 0
        maintenanceLock.unlock()

        return MaintenanceResult(
            bytesBefore: bytesBefore,
            bytesAfter: max(0, bytesAfter),
            expiredFiles: expiredFiles,
            evictedFiles: evictedFiles
        )
    }

    func fileURL(for key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(hashed)
    }

    private func entry(for url: URL) -> Entry? {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let byteCount = values.fileSize else { return nil }
        let createdAt = values.creationDate ?? values.contentModificationDate ?? .distantPast
        return Entry(
            url: url,
            byteCount: Int64(byteCount),
            createdAt: createdAt,
            lastAccessedAt: values.contentModificationDate ?? createdAt
        )
    }

    private func cacheEntries() -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap(entry(for:))
    }

    /// Only removes the file observed by the maintenance snapshot. A cache hit
    /// touches its modification date, and a replacement changes its creation or
    /// size; either means the candidate became useful while the sweep was running.
    private func remove(_ entry: Entry) -> Bool {
        guard let current = self.entry(for: entry.url),
              current.byteCount == entry.byteCount,
              current.createdAt == entry.createdAt,
              current.lastAccessedAt == entry.lastAccessedAt else { return false }
        do {
            try fileManager.removeItem(at: entry.url)
            return true
        } catch {
            return false
        }
    }

    private func recordStore(previousByteCount: Int64, byteCount: Int64) {
        maintenanceLock.lock()
        if let estimatedByteCount {
            self.estimatedByteCount = max(0, estimatedByteCount - previousByteCount + byteCount)
        }
        writesSinceReconciliation += 1
        // An unknown estimate is expected until the deferred launch sweep. Do
        // not turn every cold-start image write into another directory walk:
        // that competes directly with the poster reads the user is waiting for.
        let shouldMaintain = (estimatedByteCount ?? 0) > byteLimit
            || writesSinceReconciliation >= reconciliationWriteInterval
        maintenanceLock.unlock()
        if shouldMaintain { requestMaintenance() }
    }

    private func recordRemoval(byteCount: Int64) {
        maintenanceLock.lock()
        if let estimatedByteCount {
            self.estimatedByteCount = max(0, estimatedByteCount - byteCount)
        }
        maintenanceLock.unlock()
    }

    private func requestMaintenance() {
        guard automaticallyMaintains else { return }
        maintenanceLock.lock()
        if maintenanceRunning {
            maintenanceRequested = true
            maintenanceLock.unlock()
            return
        }
        maintenanceRunning = true
        maintenanceLock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            self?.runMaintenanceLoop()
        }
    }

    /// A launch can request dozens of posters at once. Give that user-visible
    /// work a short head start before enumerating the entire cache directory.
    private func scheduleInitialMaintenance() {
        guard automaticallyMaintains else { return }
        let delay = initialMaintenanceDelay
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestMaintenance()
        }
    }

    private func runMaintenanceLoop() {
        while true {
            let result = performMaintenance()
            if result.expiredFiles + result.evictedFiles > 0 {
                Logger.memory.info(
                    "Image disk cache removed \(result.expiredFiles) expired and \(result.evictedFiles) LRU file(s)"
                )
            }

            maintenanceLock.lock()
            if maintenanceRequested {
                maintenanceRequested = false
                maintenanceLock.unlock()
            } else {
                maintenanceRunning = false
                maintenanceLock.unlock()
                return
            }
        }
    }
}

// MARK: - Decoding

nonisolated enum ImageDecoder {
    /// Decodes raw image data into a platform image. When `maxPixelSize` is set,
    /// uses ImageIO to decode a thumbnail no larger than that on its longest
    /// edge — this both saves memory and is far faster than decoding full-size
    /// artwork only to draw it into a small card. `nil` decodes at full
    /// resolution (used for tvOS 4K heroes).
    ///
    /// Both sizes go through the same ImageIO path because of
    /// `kCGImageSourceShouldCacheImmediately`: it forces the pixels to be produced
    /// *here*, on the pipeline's detached load task. `PlatformImage(data:)` — what
    /// the full-resolution branch used to return — only wraps the bytes, so the
    /// decode happened lazily on the main thread the first time the image was
    /// drawn: a whole 4K JPEG, on the frame a hero or backdrop fades in. Leaving
    /// `kCGImageSourceThumbnailMaxPixelSize` unset yields the original dimensions,
    /// so full resolution still means full resolution.
    static func decode(_ data: Data, maxPixelSize: CGFloat?) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return PlatformImage(data: data)
        }

        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let maxPixelSize {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return PlatformImage(data: data)
        }

        #if canImport(UIKit)
            return UIImage(cgImage: cgImage)
        #else
            return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }
}

private nonisolated extension PlatformImage {
    /// Rough decoded size in bytes (w × h × 4) used as the `NSCache` cost.
    var approximateByteCost: Int {
        #if canImport(UIKit)
            let pixels = size.width * size.height * scale * scale
        #else
            let pixels = size.width * size.height
        #endif
        return Int(pixels) * 4
    }
}
