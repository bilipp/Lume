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

    private let directory: URL
    private let fileManager = FileManager.default

    private init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("LumeImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The on-disk cache directory, exposed so the Storage screen can sum its size.
    var directoryURL: URL {
        directory
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func store(_ data: Data, for key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(hashed)
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
