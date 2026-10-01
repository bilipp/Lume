//
//  ContentIndexingServicePlaybackTests.swift
//  LumeTests
//
//  The playback hold that pauses background indexing is keyed by owner, so one
//  player surface closing can't resume indexing under another still playing.
//  The service is a singleton with a private init: each test uses owner tokens
//  of its own and releases them before returning, with no suspension point in
//  between for another main-actor test to interleave.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct ContentIndexingServicePlaybackTests {
    private let service = ContentIndexingService.shared
    private let first = "ContentIndexingServicePlaybackTests-a-\(UUID().uuidString)"
    private let second = "ContentIndexingServicePlaybackTests-b-\(UUID().uuidString)"

    @Test
    func `playback stays active until every holder has resumed`() {
        defer {
            service.resume(for: first)
            service.resume(for: second)
        }

        service.suspend(for: first)
        service.suspend(for: second)
        service.resume(for: first)
        #expect(service.isPlaybackActive)

        service.resume(for: second)
        #expect(!service.isPlaybackActive)
    }

    @Test
    func `suspending twice and resuming twice is harmless`() {
        defer { service.resume(for: first) }

        service.suspend(for: first)
        service.suspend(for: first)
        service.resume(for: first)
        #expect(!service.isPlaybackActive)

        service.resume(for: first)
        #expect(!service.isPlaybackActive)

        service.suspend(for: first)
        #expect(service.isPlaybackActive)
    }
}
