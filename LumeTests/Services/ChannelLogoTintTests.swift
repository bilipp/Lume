//
//  ChannelLogoTintTests.swift
//  LumeTests
//
//  Covers the Live TV glow colour: which logos yield a tint, the accent
//  fallback, and the bounded in-memory cache in front of the analysis.
//

import CoreGraphics
import Foundation
@testable import Lume
import SwiftUI
import Testing

struct ChannelLogoTintTests {
    /// A 40×40 logo: `background` everywhere, then a `band` colour across the
    /// bottom `fraction` of its height.
    private nonisolated static func logo(
        background: (Double, Double, Double, Double),
        band: ((Double, Double, Double), Double)? = nil
    ) -> CGImage {
        let size = 40
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: background.3)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if let band {
            let (colour, fraction) = band
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(size), height: Double(size) * fraction))
        }
        return context.makeImage()!
    }

    private nonisolated static let redLogo = logo(background: (1, 1, 1, 1), band: ((0.8, 0.1, 0.1), 0.4))
    private nonisolated static let whiteLogo = logo(background: (1, 1, 1, 1))
    private nonisolated static let blackLogo = logo(background: (0, 0, 0, 1))
    private nonisolated static let transparentLogo = logo(background: (0, 0, 0, 0))

    /// Records every URL the cache asks to load.
    private actor LoadLog {
        private(set) var urls: [String] = []
        func record(_ url: URL) {
            urls.append(url.absoluteString)
        }

        func count(of url: String) -> Int {
            urls.count(where: { $0 == url })
        }
    }

    private func cache(
        capacity: Int = ChannelLogoTintCache.defaultCapacity,
        log: LoadLog,
        image: @escaping @Sendable (URL) -> CGImage? = { _ in redLogo }
    ) -> ChannelLogoTintCache {
        ChannelLogoTintCache(capacity: capacity) { url in
            await log.record(url)
            return image(url)
        }
    }

    // MARK: - Glow colour

    @Test func `a saturated logo tints the glow`() async throws {
        let tint = try #require(await cache(log: LoadLog()).tint(forLogo: "https://a/red.png"))
        #expect(tint.hasPrefix("CC"))
        #expect(LiveTVPalette.glowColor(forTintHex: tint) == TeamPalette.usableTint(fromHex: tint))
        #expect(LiveTVPalette.glowColor(forTintHex: tint) != LiveTVPalette.accent)
    }

    @Test func `white, black and transparent logos fall back to the accent`() async {
        let images = ["white": Self.whiteLogo, "black": Self.blackLogo, "clear": Self.transparentLogo]
        let cache = cache(log: LoadLog()) { url in images[url.lastPathComponent] }
        for name in images.keys {
            let tint = await cache.tint(forLogo: "https://a/\(name)")
            #expect(tint == nil)
            #expect(LiveTVPalette.glowColor(forTintHex: tint) == LiveTVPalette.accent)
        }
    }

    @Test func `missing, empty and contrast-failing hexes fall back to the accent`() {
        #expect(LiveTVPalette.glowColor(forTintHex: nil) == LiveTVPalette.accent)
        #expect(LiveTVPalette.glowColor(forTintHex: "") == LiveTVPalette.accent)
        #expect(LiveTVPalette.glowColor(forTintHex: "FFFFFF") == LiveTVPalette.accent)
        #expect(LiveTVPalette.glowColor(forTintHex: "000000") == LiveTVPalette.accent)
        #expect(LiveTVPalette.glowColor(forTintHex: "zz") == LiveTVPalette.accent)
    }

    @Test func `a missing or empty logo is never loaded`() async {
        let log = LoadLog()
        let cache = cache(log: log)
        #expect(await cache.tint(forLogo: nil) == nil)
        #expect(await cache.tint(forLogo: "") == nil)
        #expect(await log.urls.isEmpty)
    }

    // MARK: - Cache

    @Test func `a logo is analysed once and a miss is remembered`() async {
        let log = LoadLog()
        let cache = cache(log: log) { url in url.lastPathComponent == "red" ? Self.redLogo : Self.whiteLogo }
        let first = await cache.tint(forLogo: "https://a/red")
        #expect(first != nil)
        #expect(await cache.tint(forLogo: "https://a/red") == first)
        #expect(await cache.tint(forLogo: "https://a/white") == nil)
        #expect(await cache.tint(forLogo: "https://a/white") == nil)
        #expect(await log.count(of: "https://a/red") == 1)
        #expect(await log.count(of: "https://a/white") == 1)
    }

    @Test func `a logo that fails to load is retried`() async {
        let log = LoadLog()
        let cache = cache(log: log) { _ in nil }
        #expect(await cache.tint(forLogo: "https://a/offline") == nil)
        #expect(await cache.tint(forLogo: "https://a/offline") == nil)
        #expect(await log.count(of: "https://a/offline") == 2)
    }

    @Test func `the cache evicts the least recently used logo past its bound`() async {
        let log = LoadLog()
        let cache = cache(capacity: 2, log: log)
        _ = await cache.tint(forLogo: "https://a/1")
        _ = await cache.tint(forLogo: "https://a/2")
        _ = await cache.tint(forLogo: "https://a/1")
        _ = await cache.tint(forLogo: "https://a/3")

        _ = await cache.tint(forLogo: "https://a/1")
        _ = await cache.tint(forLogo: "https://a/3")
        #expect(await log.count(of: "https://a/1") == 1)
        #expect(await log.count(of: "https://a/3") == 1)

        _ = await cache.tint(forLogo: "https://a/2")
        #expect(await log.count(of: "https://a/2") == 2)
    }
}
