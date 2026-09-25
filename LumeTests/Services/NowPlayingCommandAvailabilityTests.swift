//
//  NowPlayingCommandAvailabilityTests.swift
//  LumeTests
//
//  Covers `NowPlayingService.advanceCommandsEnabled` — the rule that decides
//  whether the lock screen, Control Center and headsets show next/previous
//  track at all. Both halves matter: the stream has to have an axis, and the
//  player host has to have supplied an advance handler. tvOS supplies none, so
//  without the second half it would advertise two buttons whose every press
//  could only answer `.noActionableNowPlayingItem`.
//

import Foundation
@testable import Lume
import Testing

struct NowPlayingCommandAvailabilityTests {
    private func makeMedia(
        id: String,
        kind: PlayableMedia.Kind,
        contentRef: PlayableMedia.ContentRef
    ) throws -> PlayableMedia {
        try PlayableMedia(
            id: id,
            url: #require(URL(string: "http://example.com/\(id).ts")),
            title: "Stream",
            subtitle: nil,
            posterURL: nil,
            kind: kind,
            startTime: 0,
            contentRef: contentRef
        )
    }

    @Test func `a host with an advance handler offers the commands on both axes`() throws {
        let channel = try makeMedia(id: "live-1", kind: .live, contentRef: .live("live-1"))
        let episode = try makeMedia(id: "episode-e1", kind: .vod, contentRef: .episode("e1"))

        #expect(NowPlayingService.advanceCommandsEnabled(for: channel, hasAdvanceHandler: true))
        #expect(NowPlayingService.advanceCommandsEnabled(for: episode, hasAdvanceHandler: true))
    }

    /// The tvOS case: the host deliberately hands over no advance handler, so
    /// the commands must stay disabled however navigable the stream is.
    @Test func `a host without an advance handler offers nothing`() throws {
        let channel = try makeMedia(id: "live-1", kind: .live, contentRef: .live("live-1"))
        let episode = try makeMedia(id: "episode-e1", kind: .vod, contentRef: .episode("e1"))

        #expect(!NowPlayingService.advanceCommandsEnabled(for: channel, hasAdvanceHandler: false))
        #expect(!NowPlayingService.advanceCommandsEnabled(for: episode, hasAdvanceHandler: false))
    }

    /// Per-media gating survives the new handler check: a movie and a catch-up
    /// recording have no axis, so a host that does navigate still shows no dead
    /// buttons for them.
    @Test func `streams with no axis stay disabled even with a handler`() throws {
        let movie = try makeMedia(id: "movie-m2", kind: .vod, contentRef: .movie("m2"))
        let catchUp = try makeMedia(id: "catchup-live-1", kind: .vod, contentRef: .live("live-1"))

        #expect(!NowPlayingService.advanceCommandsEnabled(for: movie, hasAdvanceHandler: true))
        #expect(!NowPlayingService.advanceCommandsEnabled(for: catchUp, hasAdvanceHandler: true))
    }
}
