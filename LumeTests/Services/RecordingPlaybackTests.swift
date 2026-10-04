//
//  RecordingPlaybackTests.swift
//  LumeTests
//
//  Recording playback: the `PlayableMedia.recording` factory, `ContentRef`
//  Codable compatibility, the per-device resume store, and that a recording
//  stays out of every catalog-side path (favorites, watch state, trackers,
//  next episode, Now Playing's live handling, the resume snapshot).
//

import Foundation
@testable import Lume
import LumeRecorderKit
import SwiftData
import Testing

struct RecordingPlaybackTests {
    private let recordingID = UUID()

    private func makeRecording(status: RecordingStatus = .completed) -> Recording {
        Recording(
            id: recordingID, title: "Evening News", channelName: "News One",
            channelLogoURL: URL(string: "http://example.com/logo.png"), programmeDescription: nil,
            sourceRef: nil, start: .now, end: .now.addingTimeInterval(3600), status: status,
            failureReason: nil, createdAt: .now, startedAt: nil, finishedAt: nil, durationSeconds: nil, sizeBytes: nil
        )
    }

    private func makeMedia(startTime: TimeInterval = 0) throws -> PlayableMedia {
        let grant = try PlaybackGrant(
            url: #require(URL(string: "http://192.168.1.20:8090/play/abc/index.m3u8")),
            expiresAt: .now.addingTimeInterval(3600)
        )
        return PlayableMedia.recording(makeRecording(), grant: grant, startTime: startTime)
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "RecordingPlaybackTests-\(UUID().uuidString)"))
    }

    // MARK: - Factory

    @Test func `recording media is VOD with a recording identity`() throws {
        let media = try makeMedia(startTime: 42)
        let identifier = recordingID.uuidString.lowercased()

        #expect(media.id == "recording-\(identifier)")
        #expect(media.kind == .vod)
        #expect(!media.isLive)
        #expect(media.contentRef == .recording(identifier))
        #expect(media.contentRef.isRecording)
        #expect(media.title == "Evening News")
        #expect(media.subtitle == "News One")
        #expect(media.posterURL?.absoluteString == "http://example.com/logo.png")
        #expect(media.startTime == 42)
        #expect(media.httpHeaders == nil)
    }

    @Test func `catalog refs are not recordings`() {
        #expect(!PlayableMedia.ContentRef.movie("m").isRecording)
        #expect(!PlayableMedia.ContentRef.episode("e").isRecording)
        #expect(!PlayableMedia.ContentRef.live("l").isRecording)
    }

    // MARK: - Codable

    @Test func `a recording ref round-trips through Codable`() throws {
        let media = try makeMedia(startTime: 10)
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: JSONEncoder().encode(media))
        #expect(decoded.contentRef == media.contentRef)
        #expect(decoded.startTime == 10)
    }

    @Test func `payloads written before recordings still decode`() throws {
        let json = """
        {"id":"live-1","url":"http://example.com/1.ts","title":"News","kind":{"live":{}},\
        "startTime":0,"contentRef":{"live":{"_0":"p-live-1"}}}
        """
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: Data(json.utf8))
        #expect(decoded.contentRef == .live("p-live-1"))
        #expect(decoded.kind == .live)
    }

    // MARK: - Resume store

    @Test func `resume position is stored per recording at session end`() throws {
        let defaults = try makeDefaults()
        let id = recordingID.uuidString

        RecordingProgressStore.save(recordingID: id, progress: 900, duration: 3600, defaults: defaults)

        #expect(defaults.double(forKey: "recordingProgress.\(id.lowercased())") == 900)
        #expect(RecordingProgressStore.position(for: id, defaults: defaults) == 900)
        #expect(RecordingProgressStore.resumePosition(for: makeRecording(), defaults: defaults) == 900)
    }

    @Test func `a reset clock never erases the stored position`() throws {
        let defaults = try makeDefaults()
        let id = recordingID.uuidString
        RecordingProgressStore.save(recordingID: id, progress: 900, duration: 3600, defaults: defaults)

        RecordingProgressStore.save(recordingID: id, progress: 0, duration: 0, defaults: defaults)

        #expect(RecordingProgressStore.position(for: id, defaults: defaults) == 900)
    }

    @Test func `watching to the end clears the resume point`() throws {
        let defaults = try makeDefaults()
        let id = recordingID.uuidString
        RecordingProgressStore.save(recordingID: id, progress: 900, duration: 3600, defaults: defaults)

        RecordingProgressStore.save(recordingID: id, progress: 3500, duration: 3600, defaults: defaults)

        #expect(RecordingProgressStore.position(for: id, defaults: defaults) == 0)
    }

    @Test func `pending recordings open at the start`() throws {
        let defaults = try makeDefaults()
        RecordingProgressStore.save(recordingID: recordingID.uuidString, progress: 900, duration: 3600, defaults: defaults)

        #expect(RecordingProgressStore.resumePosition(for: makeRecording(status: .recording), defaults: defaults) == 0)
        #expect(RecordingProgressStore.resumePosition(for: makeRecording(status: .scheduled), defaults: defaults) == 0)
    }

    // MARK: - Catalog isolation

    @Test func `recordings have no transport axis or lock-screen track commands`() throws {
        let media = try makeMedia()
        #expect(PlayerItemNavigation.axis(for: media) == nil)
        #expect(!NowPlayingService.advanceCommandsEnabled(for: media, hasAdvanceHandler: true))
    }

    @MainActor
    @Test func `recordings resolve no catalog content`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let ref = try makeMedia().contentRef

        #expect(PlayerContentLookup.playlist(for: ref, in: context) == nil)
        #expect(!PlayerFavorites.isFavorite(for: ref, in: context))
        #expect(!PlayerFavorites.toggle(for: ref, in: context))
        #expect(SubtitleSearchQuery.resolve(for: ref, in: context) == nil)
        #expect(IntroSkipResolver.lookup(for: ref, in: context) == nil)
        #expect(NextEpisodeResolver.nextMedia(after: ref, in: context) == nil)
    }

    @Test func `recordings write no watch progress`() async throws {
        let container = try makeTestContainer()
        let writer = WatchProgressWriter(container: container)
        let ref = try makeMedia().contentRef

        let recorded = await writer.record(ref: ref, progress: 3500, duration: 3600, force: true)
        let completed = await writer.markWatched(ref: ref, duration: 3600)

        #expect(recorded == nil)
        #expect(completed == nil)
    }

    @MainActor
    @Test func `a recording clears the resume snapshot instead of storing its signed URL`() throws {
        let key = "nowPlaying.lastMediaSnapshot"
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let channel = try PlayableMedia(
            id: "live-1", url: #require(URL(string: "http://example.com/1.ts")), title: "News",
            subtitle: nil, posterURL: nil, kind: .live, startTime: 0, contentRef: .live("p-live-1")
        )
        PlaybackResumeStore.save(channel)
        #expect(PlaybackResumeStore.load()?.id == channel.id)

        try PlaybackResumeStore.save(makeMedia())

        #expect(PlaybackResumeStore.load() == nil)
    }
}
