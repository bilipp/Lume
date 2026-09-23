//
//  SportsCrestTint.swift
//  Lume
//
//  The fallback team colour for teams the provider sends without one — every
//  County Championship and T20 Blast club, a third of the T20 World Cup, the odd
//  team in any sport — and for provider colours too pale or too dark to tint a
//  card. The colour is read off the team's crest: the most common saturated
//  colour in a small thumbnail that also clears `TeamPalette`'s contrast floor,
//  so a white or gold crest field never wins over the badge itself. A crest with
//  no such colour yields nothing, and the card keeps its neutral tint.
//
//  `SportsCrestTintCache` remembers each crest's answer (a miss too) in
//  `Caches/Sports/crest-tints-v1.json`, so a crest is analysed once, not on every
//  refresh; bump the file's version when the extraction changes, or old misses
//  stick. Downloads and the pixel pass run in parallel, off the main actor.
//

import CoreGraphics
import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - Extraction

nonisolated enum SportsCrestTint {
    /// Longest edge the crest is decoded at. At 48 px anti-aliased outlines
    /// outweighed thin badges; 96 px lets the fills win.
    static let thumbnailSize: CGFloat = 96

    /// Pixels fainter than this are background, not crest.
    private static let minAlpha: Double = 0.5
    /// Pixels greyer than this saturation are outlines, text or white fields.
    private static let minSaturation: Double = 0.25
    /// Pixels darker than this are near-black. Near-white needs no bound of
    /// its own: it fails the saturation test.
    private static let minBrightness: Double = 0.12
    /// The winning colour must cover at least this share of the crest's opaque
    /// pixels to count as the crest's colour rather than a detail. Low, because
    /// shaded crests spread one colour over several buckets (Derbyshire's navy
    /// is ~3% per shade).
    private static let minCoverage: Double = 0.02

    /// The crest's most common saturated colour that is usable as a card tint,
    /// as `RRGGBB`; `nil` when the crest is monochrome, pale, or transparent.
    static func dominantHex(of image: CGImage) -> String? {
        guard let pixels = rgbaPixels(of: image) else { return nil }
        let (buckets, opaque) = colourBuckets(pixels)
        guard opaque > 0 else { return nil }

        var larger: [Shade] = []
        for bucket in buckets.sorted(by: { $0.count > $1.count }) {
            guard Double(bucket.count) / Double(opaque) >= minCoverage else { break }
            let count = Double(bucket.count)
            let red = bucket.red / count
            let green = bucket.green / count
            let blue = bucket.blue / count
            let shade = Shade(red: red, green: green, blue: blue)
            defer { larger.append(shade) }
            // A much darker copy of a bigger colour's hue is that colour's
            // anti-aliased edge against black (Dortmund's yellow into its black
            // lettering reads as olive), not a colour of its own.
            if larger.contains(where: { shade.isShadow(of: $0) }) { continue }
            let candidate = hex(red: red, green: green, blue: blue)
            if TeamPalette.usableTint(fromHex: candidate) != nil { return candidate }
        }
        return nil
    }

    private typealias Bucket = (count: Int, red: Double, green: Double, blue: Double)

    /// The image redrawn as premultiplied sRGB RGBA, at most `thumbnailSize` wide.
    private static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = min(image.width, Int(thumbnailSize))
        let height = min(image.height, Int(thumbnailSize))
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The saturated, mid-brightness pixels quantised to 3 bits per channel.
    /// Each bucket keeps its sum so the answer is the bucket's average, not its
    /// corner; `opaque` counts every visible pixel, coloured or not.
    private static func colourBuckets(_ pixels: [UInt8]) -> (buckets: [Bucket], opaque: Int) {
        var buckets: [Int: Bucket] = [:]
        var opaque = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha >= minAlpha else { continue }
            opaque += 1
            let red = Double(pixels[offset]) / 255 / alpha
            let green = Double(pixels[offset + 1]) / 255 / alpha
            let blue = Double(pixels[offset + 2]) / 255 / alpha
            let brightness = max(red, green, blue)
            let saturation = brightness == 0 ? 0 : (brightness - min(red, green, blue)) / brightness
            guard saturation >= minSaturation, brightness >= minBrightness else { continue }
            let key = (quantise(red) << 6) | (quantise(green) << 3) | quantise(blue)
            let bucket = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (bucket.count + 1, bucket.red + red, bucket.green + green, bucket.blue + blue)
        }
        return (Array(buckets.values), opaque)
    }

    /// A bucket's hue and brightness, for telling a colour from its own edge.
    private struct Shade {
        let hue: Double
        let brightness: Double

        private static let hueTolerance: Double = 20
        private static let brightnessRatio: Double = 0.5

        init(red: Double, green: Double, blue: Double) {
            let high = max(red, green, blue)
            let delta = high - min(red, green, blue)
            brightness = high
            guard delta > 0 else {
                hue = 0
                return
            }
            let sector = if high == red {
                (green - blue) / delta
            } else if high == green {
                (blue - red) / delta + 2
            } else {
                (red - green) / delta + 4
            }
            let degrees = sector * 60
            hue = degrees < 0 ? degrees + 360 : degrees
        }

        func isShadow(of other: Shade) -> Bool {
            let distance = abs(hue - other.hue)
            return min(distance, 360 - distance) < Self.hueTolerance
                && brightness < other.brightness * Self.brightnessRatio
        }
    }

    private static func quantise(_ component: Double) -> Int {
        min(7, max(0, Int(component * 8)))
    }

    private static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int {
            min(255, max(0, Int((value * 255).rounded())))
        }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

// MARK: - Cache

actor SportsCrestTintCache {
    static let shared = SportsCrestTintCache()

    /// Crest URL → its tint; `""` records a crest that has none, so it is not
    /// downloaded and analysed again.
    private var tints: [String: String]
    private let fileURL: URL
    private let loadImage: @Sendable (URL) async -> CGImage?

    init(
        fileURL: URL? = nil,
        loadImage: @escaping @Sendable (URL) async -> CGImage? = SportsCrestTintCache.pipelineImage
    ) {
        let url = fileURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sports", isDirectory: true)
            .appendingPathComponent("crest-tints-v1.json")
        self.fileURL = url
        self.loadImage = loadImage
        tints = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The tints already known for `crests` — no download, so a refresh can
    /// publish with them straight away.
    func cachedTints(for crests: Set<URL>) -> [URL: String] {
        var result: [URL: String] = [:]
        for crest in crests {
            if let tint = tints[crest.absoluteString], !tint.isEmpty { result[crest] = tint }
        }
        return result
    }

    /// The crests among `crests` that have never been analysed.
    func unseen(_ crests: Set<URL>) -> Set<URL> {
        crests.filter { tints[$0.absoluteString] == nil }
    }

    /// Fetches and analyses `crests` in parallel and returns the tints found. A
    /// crest that fails to load is not remembered, so the next refresh retries it.
    func learnTints(for crests: Set<URL>) async -> [URL: String] {
        guard !crests.isEmpty else { return [:] }
        let loadImage = loadImage
        let analysed = await withTaskGroup(of: (URL, String?)?.self) { group in
            for crest in crests {
                group.addTask {
                    guard let image = await loadImage(crest) else { return nil }
                    return (crest, SportsCrestTint.dominantHex(of: image))
                }
            }
            var out: [(URL, String?)] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
        }
        guard !analysed.isEmpty else { return [:] }
        var learned: [URL: String] = [:]
        for (crest, tint) in analysed {
            tints[crest.absoluteString] = tint ?? ""
            if let tint { learned[crest] = tint }
        }
        persist()
        return learned
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tints) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Loads through the shared image pipeline, so a crest the hub already shows
    /// comes from its caches instead of the network.
    static let pipelineImage: @Sendable (URL) async -> CGImage? = { url in
        guard let image = try? await ImagePipeline.shared.image(for: url, maxPixelSize: SportsCrestTint.thumbnailSize) else {
            return nil
        }
        #if canImport(UIKit)
            return image.cgImage
        #else
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

// MARK: - Applying tints

nonisolated extension SportsTeam {
    /// The crest a colour can be read from, for a team whose provider colour is
    /// missing or fails the card's contrast floor.
    var crestNeedingTint: URL? {
        guard TeamPalette.usableTint(fromHex: colorHex) == nil else { return nil }
        return logoURL
    }

    /// A copy tinted from its crest, when it had no usable colour of its own.
    func withCrestTint(from tints: [URL: String]) -> SportsTeam {
        guard let crest = crestNeedingTint, let tint = tints[crest] else { return self }
        return SportsTeam(
            leagueId: leagueId,
            teamId: teamId,
            name: name,
            shortName: shortName,
            abbreviation: abbreviation,
            logoURL: logoURL,
            darkLogoURL: darkLogoURL,
            colorHex: tint,
            alternateColorHex: alternateColorHex
        )
    }
}

nonisolated extension SportsCompetitor {
    func withCrestTint(from tints: [URL: String]) -> SportsCompetitor {
        SportsCompetitor(
            team: team.withCrestTint(from: tints),
            score: score,
            scoreText: scoreText,
            isWinner: isWinner,
            form: form,
            record: record
        )
    }
}

nonisolated extension SportsFixture {
    func withCrestTints(from tints: [URL: String]) -> SportsFixture {
        guard home?.team.crestNeedingTint != nil || away?.team.crestNeedingTint != nil else { return self }
        return SportsFixture(
            id: id,
            leagueId: leagueId,
            leagueName: leagueName,
            leagueAbbreviation: leagueAbbreviation,
            startDate: startDate,
            status: status,
            home: home?.withCrestTint(from: tints),
            away: away?.withCrestTint(from: tints),
            venue: venue,
            broadcasters: broadcasters,
            sessions: sessions,
            name: name,
            shortName: shortName,
            sessionKind: sessionKind,
            leagueLogoURL: leagueLogoURL
        )
    }
}

nonisolated extension SportsLeagueSnapshot {
    /// Every crest in the snapshot whose team came without a colour.
    var crestsNeedingTint: Set<URL> {
        var crests = Set(teams.compactMap(\.crestNeedingTint))
        for fixture in fixtures {
            if let crest = fixture.home?.team.crestNeedingTint { crests.insert(crest) }
            if let crest = fixture.away?.team.crestNeedingTint { crests.insert(crest) }
        }
        return crests
    }

    /// The snapshot with crest tints filled in for every colourless team.
    func withCrestTints(from tints: [URL: String]) -> SportsLeagueSnapshot {
        guard !tints.isEmpty else { return self }
        var copy = self
        copy.fixtures = fixtures.map { $0.withCrestTints(from: tints) }
        copy.teams = teams.map { $0.withCrestTint(from: tints) }
        return copy
    }
}
