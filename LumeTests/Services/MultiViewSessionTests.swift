//
//  MultiViewSessionTests.swift
//  LumeTests
//
//  Covers the Multi-View grid's state machine (`MultiViewSession`): the grid
//  arrangement per layout, slot identity across resizes, where the audio goes,
//  and the playlist-in-use bookkeeping the channel picker warns from.
//

import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct MultiViewSessionTests {
    // MARK: - Fixtures

    /// Mirrors the id scheme `ContentSyncManager` writes onto live streams:
    /// "<playlistUUID>-live-<streamId>". `MultiViewSession.playlistID(of:)`
    /// reads the playlist back out of that prefix.
    private func channel(_ streamID: Int, playlist: UUID = UUID()) -> PlayableMedia {
        let id = "\(playlist.uuidString)-live-\(streamID)"
        return PlayableMedia(
            id: "live-\(id)",
            url: URL(string: "http://example.com/live/\(streamID).ts")!,
            title: "Channel \(streamID)",
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live(id)
        )
    }

    // MARK: - Layout

    @Test func `two tiles sit side by side in landscape and stack in portrait`() {
        #expect(MultiViewLayout.two.arrangement(isPortrait: false) == .grid(rows: [[0, 1]]))
        #expect(MultiViewLayout.two.arrangement(isPortrait: true) == .grid(rows: [[0], [1]]))
    }

    @Test func `three tiles put the odd one on its own full-width row`() {
        #expect(MultiViewLayout.three.arrangement(isPortrait: false) == .grid(rows: [[0, 1], [2]]))
        #expect(MultiViewLayout.three.arrangement(isPortrait: true) == .grid(rows: [[0], [1], [2]]))
    }

    @Test func `four tiles stay a two by two grid in both orientations`() {
        #expect(MultiViewLayout.four.arrangement(isPortrait: false) == .grid(rows: [[0, 1], [2, 3]]))
        #expect(MultiViewLayout.four.arrangement(isPortrait: true) == .grid(rows: [[0, 1], [2, 3]]))
    }

    @Test func `the spotlight rails the three off-stage tiles beside a wide container and under a tall one`() {
        #expect(MultiViewLayout.spotlight.arrangement(isPortrait: false) == .spotlight(rail: [1, 2, 3], edge: .trailing))
        #expect(MultiViewLayout.spotlight.arrangement(isPortrait: true) == .spotlight(rail: [1, 2, 3], edge: .bottom))
    }

    @Test func `every layout lays out exactly its slot count once`() {
        for layout in MultiViewLayout.allCases {
            for isPortrait in [true, false] {
                let indices = layout.arrangement(isPortrait: isPortrait).placedIndices
                #expect(indices.sorted() == Array(0 ..< layout.slotCount))
            }
        }
    }

    // MARK: - Geometry

    /// A 16:9 container, the shape every tvOS display and most landscape phones
    /// hand the grid.
    private let landscape = CGSize(width: 1600, height: 900)

    @Test func `grid tiles fill the container and never overlap`() {
        for layout in MultiViewLayout.allCases {
            for size in [landscape, CGSize(width: 900, height: 1600)] {
                let frames = layout.frames(in: size, spacing: 8)
                #expect(frames.count == layout.slotCount)
                #expect(frames.allSatisfy { $0.width > 0 && $0.height > 0 })
                #expect(frames.allSatisfy { $0.maxX <= size.width + 0.001 && $0.maxY <= size.height + 0.001 })
                for (first, second) in pairs(frames) {
                    #expect(!first.insetBy(dx: 0.5, dy: 0.5).intersects(second.insetBy(dx: 0.5, dy: 0.5)))
                }
            }
        }
    }

    @Test func `the spotlight stage is far bigger than the tiles beside it`() {
        let frames = MultiViewLayout.spotlight.frames(in: landscape, spacing: 8)
        let stage = frames[0]
        // Full height, since the rail is alongside rather than underneath.
        #expect(stage.height == landscape.height)
        #expect(stage.width > landscape.width * 0.7)
        for rail in frames.dropFirst() {
            #expect(rail.minX > stage.maxX - 0.001)
            #expect(rail.width * rail.height < stage.width * stage.height / 5)
        }
    }

    @Test func `a tall container puts the spotlight rail under the stage`() {
        let size = CGSize(width: 900, height: 1600)
        let frames = MultiViewLayout.spotlight.frames(in: size, spacing: 8)
        #expect(frames[0].width == size.width)
        #expect(frames.dropFirst().allSatisfy { $0.minY > frames[0].maxY - 0.001 })
        // The three rail tiles share the width in a single row.
        #expect(Set(frames.dropFirst().map(\.minY)).count == 1)
    }

    @Test func `a collapsed container produces no negative frames`() {
        for layout in MultiViewLayout.allCases {
            let frames = layout.frames(in: .zero, spacing: 8)
            #expect(frames.allSatisfy { $0.width >= 0 && $0.height >= 0 })
        }
    }

    /// Every unordered pair, for the overlap check.
    private func pairs(_ frames: [CGRect]) -> [(CGRect, CGRect)] {
        var result: [(CGRect, CGRect)] = []
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                result.append((frame, other))
            }
        }
        return result
    }

    @Test func `only the grid's top row has nothing above it`() {
        // Landscape, which is the only arrangement tvOS ever shows.
        #expect(MultiViewLayout.two.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.two.isInTopRow(1, isPortrait: false))

        #expect(MultiViewLayout.three.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.three.isInTopRow(1, isPortrait: false))
        #expect(!MultiViewLayout.three.isInTopRow(2, isPortrait: false))

        #expect(MultiViewLayout.four.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.four.isInTopRow(1, isPortrait: false))
        #expect(!MultiViewLayout.four.isInTopRow(2, isPortrait: false))
        #expect(!MultiViewLayout.four.isInTopRow(3, isPortrait: false))

        // The stage runs the full height, so nothing is above it; of the rail
        // only its first tile has nothing above it either.
        #expect(MultiViewLayout.spotlight.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.spotlight.isInTopRow(1, isPortrait: false))
        #expect(!MultiViewLayout.spotlight.isInTopRow(2, isPortrait: false))
        #expect(!MultiViewLayout.spotlight.isInTopRow(3, isPortrait: false))
    }

    @Test func `a stacked grid puts only its first tile on the top row`() {
        #expect(MultiViewLayout.two.isInTopRow(0, isPortrait: true))
        #expect(!MultiViewLayout.two.isInTopRow(1, isPortrait: true))
        #expect(MultiViewLayout.three.isInTopRow(0, isPortrait: true))
        #expect(!MultiViewLayout.three.isInTopRow(1, isPortrait: true))
        // A rail under the stage leaves only the stage on the top row.
        #expect(MultiViewLayout.spotlight.isInTopRow(0, isPortrait: true))
        #expect(!MultiViewLayout.spotlight.isInTopRow(1, isPortrait: true))
    }

    @Test func `the smallest layout that fits a seed is chosen`() {
        #expect(MultiViewLayout.fitting(0) == .two)
        #expect(MultiViewLayout.fitting(1) == .two)
        #expect(MultiViewLayout.fitting(2) == .two)
        #expect(MultiViewLayout.fitting(3) == .three)
        #expect(MultiViewLayout.fitting(4) == .four)
        // A seed larger than the grid can't widen it past four tiles.
        #expect(MultiViewLayout.fitting(9) == .four)
    }

    // MARK: - Launch

    @Test func `a launch carries the channels the grid should open with`() {
        let launch = MultiViewLaunch(seed: [channel(1)])
        #expect(launch.seed.map(\.title) == ["Channel 1"])
        #expect(MultiViewLaunch().seed.isEmpty)
    }

    @Test func `every launch is its own identity`() {
        // The hosts present on this value and key the screen to its id, so two
        // launches must never look like the same one — a reused identity keeps
        // the previous session alive and drops the new seed.
        let first = MultiViewLaunch(seed: [channel(1)])
        let second = MultiViewLaunch(seed: [channel(1)])
        #expect(first.id != second.id)
    }

    // MARK: - Seeding

    @Test func `a session seeds its leading tiles and leaves the rest empty`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .four)
        #expect(session.slots.count == 4)
        #expect(session.slots[0].media?.title == "Channel 1")
        #expect(session.slots.dropFirst().allSatisfy { $0.media == nil })
        #expect(session.activeMedia.count == 1)
    }

    @Test func `the first seeded tile carries the audio`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        #expect(session.isAudioSlot(session.slots[0].id))
        #expect(!session.isAudioSlot(session.slots[1].id))
    }

    // MARK: - Audio

    @Test func `the first channel added takes the audio`() {
        let session = MultiViewSession()
        // Fill the *second* tile: the audio should follow the only thing playing,
        // not stay pinned to tile one.
        session.setMedia(channel(1), in: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `a later channel does not steal the audio`() {
        let session = MultiViewSession()
        session.setMedia(channel(1), in: session.slots[0].id)
        session.setMedia(channel(2), in: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    @Test func `the audio moves to a tile that is playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        session.focusAudio(on: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `an empty tile cannot take the audio`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .two)
        session.focusAudio(on: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    @Test func `clearing the audible tile hands the audio to one still playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        session.setMedia(nil, in: session.slots[0].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `clearing the last channel leaves the audio on that tile`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .two)
        let first = session.slots[0].id
        session.setMedia(nil, in: first)
        #expect(session.isAudioSlot(first))
        #expect(session.activeMedia.isEmpty)
    }

    // MARK: - Resizing

    @Test func `growing the grid keeps the tiles that were already playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        let originalIDs = session.slots.map(\.id)
        session.layout = .four
        #expect(session.slots.count == 4)
        // Identity must survive, or SwiftUI would tear down a running player.
        #expect(Array(session.slots.prefix(2).map(\.id)) == originalIDs)
        #expect(session.activeMedia.count == 2)
    }

    @Test func `shrinking the grid drops the trailing tiles`() {
        let session = MultiViewSession(seed: [channel(1), channel(2), channel(3), channel(4)], layout: .four)
        let keptIDs = Array(session.slots.prefix(2).map(\.id))
        session.layout = .two
        #expect(session.slots.map(\.id) == keptIDs)
        #expect(session.activeMedia.map(\.title) == ["Channel 1", "Channel 2"])
    }

    @Test func `shrinking away the audible tile hands the audio to a survivor`() {
        let session = MultiViewSession(seed: [channel(1), channel(2), channel(3)], layout: .three)
        session.focusAudio(on: session.slots[2].id)
        session.layout = .two
        #expect(session.slots.count == 2)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    // MARK: - Spotlight

    @Test func `promoting a tile trades it with the one on stage`() {
        let session = MultiViewSession(
            seed: [channel(1), channel(2), channel(3), channel(4)],
            layout: .spotlight
        )
        let originalIDs = session.slots.map(\.id)
        session.promote(originalIDs[2])
        #expect(session.slots.map(\.media?.title) == ["Channel 3", "Channel 2", "Channel 1", "Channel 4"])
        // The tiles trade places rather than being rebuilt — a new identity in
        // either position would tear a running player down.
        #expect(session.slots.map(\.id) == [originalIDs[2], originalIDs[1], originalIDs[0], originalIDs[3]])
    }

    @Test func `the audio follows the tile promoted to the stage`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .spotlight)
        session.promote(session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[0].id))
        #expect(session.slots[0].media?.title == "Channel 2")
    }

    @Test func `promoting the tile already on stage changes nothing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .spotlight)
        let originalIDs = session.slots.map(\.id)
        session.promote(originalIDs[0])
        #expect(session.slots.map(\.id) == originalIDs)
        #expect(session.slots[0].media?.title == "Channel 1")
    }

    @Test func `switching into the spotlight moves the audio onto the stage`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        session.focusAudio(on: session.slots[1].id)
        session.layout = .spotlight
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    @Test func `a channel dropped onto the stage takes the audio from a rail tile`() {
        let session = MultiViewSession(layout: .spotlight)
        session.setMedia(channel(2), in: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[1].id))
        session.setMedia(channel(1), in: session.slots[0].id)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    @Test func `an empty stage leaves the audio on a rail tile that is playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .spotlight)
        session.setMedia(nil, in: session.slots[0].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `only the spotlight has a stage`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .four)
        #expect(!session.hasSpotlight)
        #expect(!session.isStageSlot(session.slots[0].id))
        session.layout = .spotlight
        #expect(session.hasSpotlight)
        #expect(session.isStageSlot(session.slots[0].id))
        #expect(!session.isStageSlot(session.slots[1].id))
    }

    @Test func `the spotlight keeps the four tiles the grid already had`() {
        let session = MultiViewSession(
            seed: [channel(1), channel(2), channel(3), channel(4)],
            layout: .four
        )
        let originalIDs = session.slots.map(\.id)
        session.layout = .spotlight
        #expect(session.slots.count == 4)
        #expect(session.slots.map(\.id) == originalIDs)
    }

    // MARK: - Picker bookkeeping

    @Test func `channels on screen are reported so the picker can mark them`() {
        let first = channel(1)
        let session = MultiViewSession(seed: [first], layout: .two)
        #expect(session.usedMediaIDs == [first.id])
    }

    @Test func `the playlist behind a live stream is read from its id prefix`() throws {
        let playlist = UUID()
        let resolved = try #require(MultiViewSession.playlistID(of: channel(7, playlist: playlist)))
        #expect(resolved == playlist)
    }

    @Test func `playlists feeding other tiles are reported, excluding the tile being changed`() {
        let playlistA = UUID()
        let playlistB = UUID()
        let session = MultiViewSession(
            seed: [channel(1, playlist: playlistA), channel(2, playlist: playlistB)],
            layout: .two
        )
        #expect(session.playlistsInUse() == [playlistA, playlistB])
        // Re-picking tile one must not warn about tile one's own playlist.
        #expect(session.playlistsInUse(excluding: session.slots[0].id) == [playlistB])
    }

    @Test func `two tiles on one playlist report it once`() {
        let playlist = UUID()
        let session = MultiViewSession(
            seed: [channel(1, playlist: playlist), channel(2, playlist: playlist)],
            layout: .two
        )
        #expect(session.playlistsInUse() == [playlist])
    }
}
