//
//  RecordingServerTypesTests.swift
//  LumeTests
//
//  The LumeRecorderKit → app-type mappers: every field carries over, ids keep
//  the resume keys earlier builds wrote, and a create request only maps back
//  for a stream-URL target.
//

import Foundation
@testable import Lume
import LumeRecorderKit
import Testing

struct RecordingServerTypesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `a Kit recording maps field by field`() throws {
        let id = UUID()
        let recording = try Recording(
            id: id, title: "Evening News", channelName: "News One",
            channelLogoURL: #require(URL(string: "http://example.com/logo.png")),
            programmeDescription: "Headlines", sourceRef: "ref", start: now, end: now.addingTimeInterval(3600),
            status: .failed, failureReason: "stream ended", createdAt: now.addingTimeInterval(-60),
            startedAt: now.addingTimeInterval(5), finishedAt: now.addingTimeInterval(1200),
            durationSeconds: 1195, sizeBytes: 42
        )

        let mapped = ServerRecording(recording)

        #expect(mapped.id == RecordingID(id))
        #expect(mapped.id.rawValue == id.uuidString)
        #expect(mapped.id.uuid == id)
        #expect(mapped.title == "Evening News")
        #expect(mapped.channelName == "News One")
        #expect(mapped.channelLogoURL == recording.channelLogoURL)
        #expect(mapped.programmeDescription == "Headlines")
        #expect(mapped.sourceRef == "ref")
        #expect(mapped.start == recording.start)
        #expect(mapped.end == recording.end)
        #expect(mapped.status == .failed)
        #expect(mapped.failureReason == "stream ended")
        #expect(mapped.createdAt == recording.createdAt)
        #expect(mapped.startedAt == recording.startedAt)
        #expect(mapped.finishedAt == recording.finishedAt)
        #expect(mapped.durationSeconds == 1195)
        #expect(mapped.sizeBytes == 42)
        #expect(!mapped.isPartial)
    }

    @Test func `the resume key of a LumeRecorder recording is unchanged`() {
        let id = UUID()
        #expect(RecordingProgressStore.identifier(for: RecordingID(id)) == id.uuidString.lowercased())
        #expect(RecordingProgressStore.key(for: RecordingProgressStore.identifier(for: RecordingID(id)))
            == "recordingProgress.\(id.uuidString.lowercased())")
    }

    @Test(arguments: ["scheduled", "recording", "completed", "failed", "cancelled", "archived"])
    func `statuses map by raw value`(raw: String) {
        let mapped = ServerRecordingStatus(RecordingStatus(rawValue: raw))
        #expect(mapped.rawValue == raw)
        #expect(mapped.isPending == RecordingStatus(rawValue: raw).isPending)
    }

    @Test func `an unknown status is kept`() {
        #expect(ServerRecordingStatus(RecordingStatus(rawValue: "archived")) == .unknown("archived"))
    }

    @Test func `a non-UUID id has no UUID`() {
        #expect(RecordingID(rawValue: "17").uuid == nil)
    }

    @Test func `server info and status map`() {
        let serverID = UUID()
        let identity = ServerIdentity(ServerInfo(id: serverID, name: "Den", version: "0.1.1", apiVersion: 1))
        #expect(identity == ServerIdentity(id: serverID, name: "Den", version: "0.1.1"))

        let status = RecordingServerStatus(ServerStatus(
            activeRecordings: 1, scheduledRecordings: 3, freeDiskBytes: 100, totalDiskBytes: 400, maxConcurrent: 2
        ))
        #expect(status == RecordingServerStatus(
            activeRecordings: 1, scheduledRecordings: 3, freeDiskBytes: 100, totalDiskBytes: 400
        ))
    }

    @Test func `a playback grant needs no headers`() throws {
        let url = try #require(URL(string: "http://192.168.1.20:8090/play/abc/index.m3u8"))
        let playback = RecordingPlayback(PlaybackGrant(url: url, expiresAt: now))
        #expect(playback.url == url)
        #expect(playback.httpHeaders.isEmpty)
    }

    @Test func `a create request maps back only for a stream URL`() throws {
        let streamURL = try #require(URL(string: "http://example.com/live/u/p/1.ts"))
        let request = RecordingCreateRequest(
            target: .streamURL(streamURL), title: "Evening News", channelName: "News One",
            programmeDescription: "Headlines", start: now, end: now.addingTimeInterval(3600), sourceRef: "ref"
        )

        let kit = try #require(CreateRecordingRequest(request))
        #expect(kit == CreateRecordingRequest(
            streamURL: streamURL, title: "Evening News", channelName: "News One",
            programmeDescription: "Headlines", start: now, end: now.addingTimeInterval(3600), sourceRef: "ref"
        ))

        var channelRequest = request
        channelRequest.target = .dispatcharrChannel(7)
        #expect(CreateRecordingRequest(channelRequest) == nil)
    }
}
