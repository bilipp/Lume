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
import SwiftData
import Testing

struct RecordingPlaybackTests {
    private let recordingID = UUID()

    private func makeRecording(status: ServerRecordingStatus = .completed) -> ServerRecording {
        ServerRecording(
            id: RecordingID(recordingID), title: "Evening News", channelName: "News One",
            channelLogoURL: URL(string: "http://example.com/logo.png"), programmeDescription: nil,
            sourceRef: nil, start: .now, end: .now.addingTimeInterval(3600), status: status,
            failureReason: nil, createdAt: .now, startedAt: nil, finishedAt: nil, durationSeconds: nil, sizeBytes: nil
        )
    }

    private func makeMedia(startTime: TimeInterval = 0) throws -> PlayableMedia {
        let playback = try RecordingPlayback(
            url: #require(URL(string: "http://192.168.1.20:8090/play/abc/index.m3u8"))
        )
        return PlayableMedia.recording(makeRecording(), playback: playback, startTime: startTime)
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

    // MARK: - Dispatcharr

    private static let dispatcharrServerID = UUID()
    private static let dispatcharrNamespace = RecordingProgressStore.namespace(kind: .dispatcharr, serverID: dispatcharrServerID)

    private func makeDispatcharrRecording(id: String = "42", status: ServerRecordingStatus = .completed) -> ServerRecording {
        ServerRecording(
            id: RecordingID(rawValue: id), title: "Harbour Lights", channelName: "Bramble TV",
            start: .now, end: .now.addingTimeInterval(3600), status: status, createdAt: .now
        )
    }

    private func makeDispatcharrMedia(
        headers: [String: String],
        path: String = "/api/channels/recordings/42/file/",
        startTime: TimeInterval = 0
    ) throws -> PlayableMedia {
        let playback = try RecordingPlayback(url: #require(URL(string: "http://192.168.1.30:9191\(path)")), httpHeaders: headers)
        return PlayableMedia.recording(
            makeDispatcharrRecording(), playback: playback, progressNamespace: Self.dispatcharrNamespace, startTime: startTime
        )
    }

    @Test func `progress ids are namespaced per Dispatcharr server, never for LumeRecorder`() throws {
        let namespace = try #require(Self.dispatcharrNamespace)
        let server = Self.dispatcharrServerID.uuidString.lowercased()

        #expect(namespace == "dispatcharr-\(server)")
        #expect(RecordingProgressStore.identifier(for: RecordingID(rawValue: "42"), namespace: namespace) == "dispatcharr-\(server)-42")
        #expect(RecordingProgressStore.namespace(kind: .lumeRecorder, serverID: Self.dispatcharrServerID) == nil)
        #expect(RecordingProgressStore.identifier(for: RecordingID(recordingID), namespace: nil) == recordingID.uuidString.lowercased())
        #expect(RecordingProgressStore.isDispatcharr("dispatcharr-\(server)-42"))
        #expect(!RecordingProgressStore.isDispatcharr(recordingID.uuidString.lowercased()))
    }

    @Test func `a paired server's namespace follows its kind and server id`() {
        func config(kind: RecordingServerKind, serverID: UUID?) -> RecordingServerConfig {
            RecordingServerConfig(
                id: UUID(), kindRaw: kind.rawValue, name: "Den", baseURL: "http://192.168.1.30:9191",
                serverID: serverID, deviceID: nil, isEnabled: true, updatedAt: .now, endpoint: nil
            )
        }
        let serverID = UUID()

        #expect(config(kind: .dispatcharr, serverID: serverID).progressNamespace == "dispatcharr-\(serverID.uuidString.lowercased())")
        #expect(config(kind: .lumeRecorder, serverID: serverID).progressNamespace == nil)
        let unknown = RecordingServerConfig(
            id: UUID(), kindRaw: "future", name: "Den", baseURL: "", serverID: serverID,
            deviceID: nil, isEnabled: true, updatedAt: .now, endpoint: nil
        )
        #expect(unknown.progressNamespace == nil)
    }

    @Test func `a Dispatcharr recording carries its headers and namespaced identity`() throws {
        let namespace = try #require(Self.dispatcharrNamespace)
        let media = try makeDispatcharrMedia(headers: ["X-API-Key": "fixture-key"], startTime: 30)

        #expect(media.contentRef == .recording("\(namespace)-42"))
        #expect(media.id == "recording-\(namespace)-42")
        #expect(media.httpHeaders == ["X-API-Key": "fixture-key"])
        #expect(media.url.query() == nil)
        #expect(media.hasEphemeralURL)
        #expect(media.startTime == 30)
    }

    @Test func `the same Dispatcharr id on two servers resumes separately`() throws {
        let defaults = try makeDefaults()
        let other = RecordingProgressStore.namespace(kind: .dispatcharr, serverID: UUID())
        let recording = makeDispatcharrRecording()
        let mine = RecordingProgressStore.identifier(for: recording.id, namespace: Self.dispatcharrNamespace)

        RecordingProgressStore.save(recordingID: mine, progress: 900, duration: 3600, defaults: defaults)

        #expect(RecordingProgressStore.resumePosition(for: recording, namespace: Self.dispatcharrNamespace, defaults: defaults) == 900)
        #expect(RecordingProgressStore.resumePosition(for: recording, namespace: other, defaults: defaults) == 0)
        #expect(RecordingProgressStore.resumePosition(for: recording, defaults: defaults) == 0)
    }

    // MARK: - Engines

    @Test func `catalog media and LumeRecorder recordings keep every engine`() throws {
        let priority: [PlayerEngineKind] = [.ksPlayer, .vlcKit, .avPlayer, .lumeEngine, .aetherEngine]
        let media = try makeMedia()

        #expect(media.unsupportedEngines.isEmpty)
        #expect(PlayerEnginePriority.playable(priority, for: media) == priority)
    }

    @Test func `an API-key Dispatcharr recording skips AVPlayer and VLC`() throws {
        let media = try makeDispatcharrMedia(headers: ["X-API-Key": "fixture-key"])

        #expect(media.unsupportedEngines == [.avPlayer, .vlcKit])
        #expect(PlayerEnginePriority.playable([.vlcKit, .avPlayer, .ksPlayer, .lumeEngine, .aetherEngine], for: media) == [.ksPlayer, .lumeEngine, .aetherEngine])
    }

    @Test func `a password Dispatcharr recording keeps VLC through the token URL`() throws {
        let media = try makeDispatcharrMedia(
            headers: ["Authorization": "Bearer header.payload.sig"], path: "/api/channels/recordings/42/hls/index.m3u8"
        )

        #expect(media.unsupportedEngines == [.avPlayer])
        #expect(PlayerEnginePriority.playable([.avPlayer, .vlcKit, .ksPlayer, .lumeEngine, .aetherEngine], for: media) == [.vlcKit, .ksPlayer, .lumeEngine, .aetherEngine])
        let vlcURL = try #require(DispatcharrPlaybackAuth.authenticatedURL(media.url, headers: media.httpHeaders))
        #expect(vlcURL.absoluteString == "http://192.168.1.30:9191/api/channels/recordings/42/hls/index.m3u8?token=header.payload.sig")
        // The token exists only in the URL handed to VLC.
        #expect(media.url.query() == nil)
    }

    @Test func `dispatcharr recordings keep AetherEngine whatever the sign-in`() throws {
        let apiKey = try makeDispatcharrMedia(headers: ["X-API-Key": "fixture-key"])
        let password = try makeDispatcharrMedia(
            headers: ["Authorization": "Bearer header.payload.sig"], path: "/api/channels/recordings/42/hls/index.m3u8"
        )

        for media in [apiKey, password] {
            #expect(!media.unsupportedEngines.contains(.aetherEngine))
            #expect(media.unsupportedEngines.contains(.avPlayer))
            #expect(PlayerEnginePriority.playable([.aetherEngine, .avPlayer], for: media) == [.aetherEngine])
        }
    }

    @Test func `filtering never leaves the player without an engine`() throws {
        let media = try makeDispatcharrMedia(headers: ["X-API-Key": "fixture-key"])
        #expect(PlayerEnginePriority.playable([.avPlayer, .vlcKit], for: media) == [.avPlayer, .vlcKit])
    }

    @Test func `the VLC token fold applies only to a Bearer header on a recording URL`() throws {
        let recordingURL = try #require(URL(string: "http://192.168.1.30:9191/api/channels/recordings/42/file/"))
        let otherURL = try #require(URL(string: "http://192.168.1.30:9191/proxy/ts/stream/abc"))
        let bearer = ["Authorization": "Bearer jwt"]

        #expect(DispatcharrPlaybackAuth.authenticatedURL(recordingURL, headers: ["X-API-Key": "key"]) == nil)
        #expect(DispatcharrPlaybackAuth.authenticatedURL(recordingURL, headers: ["Authorization": "Basic dXNlcjpwYXNz"]) == nil)
        #expect(DispatcharrPlaybackAuth.authenticatedURL(recordingURL, headers: ["Authorization": "Bearer "]) == nil)
        #expect(DispatcharrPlaybackAuth.authenticatedURL(recordingURL, headers: nil) == nil)
        #expect(DispatcharrPlaybackAuth.authenticatedURL(otherURL, headers: bearer) == nil)
        #expect(DispatcharrPlaybackAuth.authenticatedURL(recordingURL, headers: bearer)?.query() == "token=jwt")

        let alreadyTokened = try #require(URL(string: "http://192.168.1.30:9191/api/channels/recordings/42/file/?token=old"))
        #expect(DispatcharrPlaybackAuth.authenticatedURL(alreadyTokened, headers: bearer) == alreadyTokened)
    }
}
