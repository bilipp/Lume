//
//  SportsCrestTintTests.swift
//  LumeTests
//
//  Covers the crest-derived fallback tint: which colour a crest yields, the
//  cache that remembers the answer, and which teams a snapshot tints.
//

import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct SportsCrestTintTests {
    /// A 40×40 crest: `background` everywhere, then each `(colour, fraction)`
    /// painted as a horizontal band covering that share of the height, then an
    /// optional `speck` colour in a 3×3 corner square (under 1% of the crest).
    private func crest(
        background: (Double, Double, Double, Double),
        bands: [((Double, Double, Double), Double)] = [],
        speck: (Double, Double, Double)? = nil
    ) -> CGImage {
        let size = 40
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: background.3)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        var bandTop = 0.0
        for (colour, fraction) in bands {
            let height = Double(size) * fraction
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(CGRect(x: 0, y: bandTop, width: Double(size), height: height))
            bandTop += height
        }
        if let speck {
            context.setFillColor(red: speck.0, green: speck.1, blue: speck.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        return context.makeImage()!
    }

    private let white = (1.0, 1.0, 1.0, 1.0)
    private let clear = (0.0, 0.0, 0.0, 0.0)

    // MARK: - Extraction

    @Test func `a white crest with a red badge yields the red`() throws {
        let hex = try #require(SportsCrestTint.dominantHex(of: crest(background: white, bands: [((0.8, 0.1, 0.1), 0.3)])))
        #expect(hex.hasPrefix("CC"))
        #expect(TeamPalette.usableTint(fromHex: hex) != nil)
    }

    @Test func `a pale field loses to the darker colour that can tint a card`() throws {
        let gold = (0.95, 0.8, 0.1)
        let navy = (0.1, 0.15, 0.5)
        let image = crest(background: white, bands: [(gold, 0.7), (navy, 0.2)])
        let hex = try #require(SportsCrestTint.dominantHex(of: image))
        #expect(TeamPalette.usableTint(fromHex: hex) != nil)
        let channels = stride(from: 0, to: 6, by: 2).map { offset in
            Int(hex.dropFirst(offset).prefix(2), radix: 16) ?? 0
        }
        #expect(channels[2] > channels[0] && channels[2] > channels[1])
    }

    @Test func `monochrome, transparent and speck-sized colours yield nothing`() {
        #expect(SportsCrestTint.dominantHex(of: crest(background: white)) == nil)
        #expect(SportsCrestTint.dominantHex(of: crest(background: (0, 0, 0, 1), bands: [((0.5, 0.5, 0.5), 0.5)])) == nil)
        #expect(SportsCrestTint.dominantHex(of: crest(background: clear)) == nil)
        #expect(SportsCrestTint.dominantHex(of: crest(background: white, speck: (0.8, 0.1, 0.1))) == nil)
    }

    @Test func `a colour's dark edge is not mistaken for a colour of its own`() {
        let yellow = (1.0, 0.93, 0.0)
        let edge = (0.2, 0.18, 0.0)
        let image = crest(background: (0, 0, 0, 1), bands: [(yellow, 0.5), (edge, 0.1)])
        #expect(SportsCrestTint.dominantHex(of: image) == nil)
    }

    @Test func `transparent padding does not dilute the badge`() throws {
        let hex = try #require(SportsCrestTint.dominantHex(of: crest(background: clear, bands: [((0.1, 0.4, 0.8), 0.5)])))
        #expect(TeamPalette.usableTint(fromHex: hex) != nil)
    }

    // MARK: - Cache

    @Test func `the cache analyses a crest once and remembers misses`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("crest-tints.json")
        let red = try #require(URL(string: "https://a/red.png"))
        let plain = try #require(URL(string: "https://a/plain.png"))
        let redImage = crest(background: white, bands: [((0.8, 0.1, 0.1), 0.4)])
        let plainImage = crest(background: white)
        let cache = SportsCrestTintCache(fileURL: file) { url in
            url == red ? redImage : plainImage
        }

        #expect(await cache.unseen([red, plain]) == [red, plain])
        let learned = await cache.learnTints(for: [red, plain])
        #expect(learned.keys.sorted { $0.absoluteString < $1.absoluteString } == [red])
        #expect(await cache.unseen([red, plain]).isEmpty)
        #expect(await cache.cachedTints(for: [red, plain]) == learned)

        let reloaded = SportsCrestTintCache(fileURL: file) { _ in nil }
        #expect(await reloaded.cachedTints(for: [red]) == learned)
        #expect(await reloaded.unseen([plain]).isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func `a crest that fails to load is retried next time`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let crestURL = try #require(URL(string: "https://a/offline.png"))
        let cache = SportsCrestTintCache(fileURL: file) { _ in nil }
        #expect(await cache.learnTints(for: [crestURL]).isEmpty)
        #expect(await cache.unseen([crestURL]) == [crestURL])
    }

    // MARK: - Applying

    private func team(_ id: String, color: String?, logo: String?) -> SportsTeam {
        SportsTeam(
            leagueId: "espn:cricket/8052", teamId: id, name: id, shortName: id, abbreviation: id,
            logoURL: logo.flatMap(URL.init(string:)), colorHex: color
        )
    }

    @Test func `only teams without a usable colour are tinted from their crest`() throws {
        let essexCrest = try #require(URL(string: "https://a/984.png"))
        let paleCrest = try #require(URL(string: "https://a/3.png"))
        let fixture = SportsFixture(
            id: "1", leagueId: "espn:cricket/8052", leagueName: "", leagueAbbreviation: "",
            startDate: Date(), status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: team("984", color: nil, logo: essexCrest.absoluteString), scoreText: "212 & 275"),
            away: SportsCompetitor(team: team("2", color: "2561AE", logo: "https://a/2.png"))
        )
        let paleTeam = team("3", color: "FFFFFF", logo: "https://a/3.png")
        let noCrest = team("4", color: nil, logo: nil)
        let snapshot = SportsLeagueSnapshot(fixtures: [fixture], teams: [paleTeam, noCrest])

        #expect(snapshot.crestsNeedingTint == [essexCrest, paleCrest])

        let tinted = snapshot.withCrestTints(from: [essexCrest: "1A3C8C", paleCrest: "B3181E"])
        #expect(tinted.fixtures.first?.home?.team.colorHex == "1A3C8C")
        #expect(tinted.fixtures.first?.home?.scoreText == "212 & 275")
        #expect(tinted.fixtures.first?.away?.team.colorHex == "2561AE")
        #expect(tinted.teams.map(\.colorHex) == ["B3181E", nil])
        #expect(tinted.crestsNeedingTint.isEmpty)
    }
}
