//
//  ChannelLogoTint.swift
//  Lume
//
//  The colour the tvOS Live TV glow is tinted with: the dominant colour of the
//  settled channel's logo, read with the Sports Hub's crest extraction so a
//  white, black or transparent logo yields nothing and the glow falls back to
//  the Live TV accent. Video frames are never sampled.
//
//  Answers live in memory only, bounded so a long zap through a large catalogue
//  cannot grow without limit; a logo is re-analysed after a relaunch, which the
//  image pipeline's own caches make cheap.
//

import CoreGraphics
import Foundation

nonisolated enum LiveTVLogo {
    /// Longest edge every tvOS Live TV logo is decoded at, so the channel
    /// column, the hero tile and the glow's tint share one memory-cache entry.
    static let pixelSize: CGFloat = 112
}

// MARK: - Cache

actor ChannelLogoTintCache {
    static let shared = ChannelLogoTintCache()

    static let defaultCapacity = 500

    /// Logo URL → its tint; `""` records a logo that has none.
    private var tints: [String: String] = [:]
    /// Keys from least to most recently used.
    private var recency: [String] = []
    private let capacity: Int
    private let loadImage: @Sendable (URL) async -> CGImage?

    init(
        capacity: Int = ChannelLogoTintCache.defaultCapacity,
        loadImage: @escaping @Sendable (URL) async -> CGImage? = { url in
            await ImagePipeline.cgImage(for: url, maxPixelSize: LiveTVLogo.pixelSize)
        }
    ) {
        self.capacity = max(1, capacity)
        self.loadImage = loadImage
    }

    /// The logo's dominant colour as `RRGGBB`, or `nil` when it has none, fails
    /// to load, or the caller was cancelled. Only an analysed logo is
    /// remembered, so a failed or cancelled load is retried next time.
    func tint(forLogo logo: String?) async -> String? {
        guard let logo, !logo.isEmpty, let url = URL(string: logo) else { return nil }
        if let known = tints[logo] {
            touch(logo)
            return known.isEmpty ? nil : known
        }
        guard let image = await loadImage(url), !Task.isCancelled else { return nil }
        let tint = SportsCrestTint.dominantHex(of: image)
        store(tint ?? "", for: logo)
        return tint
    }

    private func store(_ tint: String, for key: String) {
        if tints.updateValue(tint, forKey: key) != nil {
            touch(key)
            return
        }
        recency.append(key)
        while recency.count > capacity {
            tints.removeValue(forKey: recency.removeFirst())
        }
    }

    private func touch(_ key: String) {
        guard let index = recency.firstIndex(of: key), index != recency.count - 1 else { return }
        recency.remove(at: index)
        recency.append(key)
    }
}
