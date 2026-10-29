//
//  RecordingServerStore+Record.swift
//  Lume
//
//  Record now and Schedule, and which channels offer them. LumeRecorder
//  records any standalone stream URL with Lume's padding; Dispatcharr records
//  only the channels it serves itself, by its own channel id, and pads on the
//  server.
//

import Foundation
import os

/// The parts of a playlist that decide whether its channels can be recorded.
/// None of them change, so one read serves every row of the playlist.
nonisolated struct RecordingPlaylistSource: Hashable {
    let id: UUID
    let sourceType: PlaylistSourceType
    /// The playlist's address, matched against a Dispatcharr server's.
    let serverURL: String
}

extension RecordingPlaylistSource {
    init(playlist: Playlist) {
        self.init(id: playlist.id, sourceType: playlist.sourceType, serverURL: playlist.serverURL)
    }
}

extension RecordingServerStore {
    // MARK: - Availability

    /// Whether a Record action belongs on this channel at all. Paired-but-lapsed
    /// still shows it, behind the crown; a view-only account never does.
    /// `playlistServed` skips the playlist-wide check for a caller that already
    /// passed `supportsRecording(in:on:)` for this pairing.
    func supportsRecording(
        _ stream: LiveStream,
        in source: RecordingPlaylistSource,
        playlistServed: Bool = false
    ) -> Bool {
        guard let endpoint = pairedEndpoint, accountCapabilities?.readOnly != true else { return false }
        return Self.isRecordable(stream, in: source, on: endpoint, playlistServed: playlistServed)
    }

    func supportsScheduling(
        _ stream: LiveStream,
        in source: RecordingPlaylistSource,
        playlistServed: Bool = false
    ) -> Bool {
        guard supportsRecording(stream, in: source, playlistServed: playlistServed),
              let capabilities = pairedCapabilities
        else { return false }
        return Self.canSchedule(source.sourceType, with: capabilities)
    }

    /// The playlist-wide part of `supportsRecording(_:in:)`: whether the
    /// paired server could record any of the playlist's channels. It depends
    /// only on the pairing, never on the account's permissions, so it can be
    /// cached per playlist and endpoint.
    func supportsRecording(in source: RecordingPlaylistSource, on endpoint: RecordingServerEndpoint) -> Bool {
        switch endpoint.kind {
        case .lumeRecorder:
            source.sourceType.supportsRecording
        case .dispatcharr:
            DispatcharrChannelLocator.isServed(source.serverURL, by: endpoint.baseURL)
        }
    }

    /// Whether ending `recording` cancels it rather than stopping it.
    func cancelsRatherThanStops(_ recording: ServerRecording) -> Bool {
        (pairedCapabilities ?? .lumeRecorder).cancelsRatherThanStops(recording, now: now())
    }

    private static func isRecordable(
        _ stream: LiveStream,
        in source: RecordingPlaylistSource,
        on endpoint: RecordingServerEndpoint,
        playlistServed: Bool = false
    ) -> Bool {
        switch endpoint.kind {
        case .lumeRecorder:
            source.sourceType.supportsRecording
        case .dispatcharr where playlistServed:
            DispatcharrChannelLocator(
                servedSourceType: source.sourceType,
                streamID: stream.streamId,
                directURL: stream.directURL,
                baseURL: endpoint.baseURL
            ) != nil
        case .dispatcharr:
            dispatcharrLocator(stream, in: source, baseURL: endpoint.baseURL) != nil
        }
    }

    private static func canSchedule(_ sourceType: PlaylistSourceType, with capabilities: RecordingServerCapabilities) -> Bool {
        capabilities.schedulesAnySource || sourceType.supportsRecordingSchedule
    }

    private static func dispatcharrLocator(
        _ stream: LiveStream,
        in source: RecordingPlaylistSource,
        baseURL: URL
    ) -> DispatcharrChannelLocator? {
        DispatcharrChannelLocator(
            sourceType: source.sourceType,
            playlistURL: source.serverURL,
            streamID: stream.streamId,
            directURL: stream.directURL,
            baseURL: baseURL
        )
    }

    // MARK: - Record

    /// Starts recording `stream` now: until the airing `programme` ends (plus
    /// Lume's post-roll where Lume pads), or for `duration` when no programme
    /// is on air.
    @discardableResult
    func recordNow(
        stream: LiveStream,
        playlist: Playlist,
        programme: RecordingRequestPlanner.Programme?,
        duration: RecordingRequestPlanner.FallbackDuration? = nil
    ) async throws(RecordingActionError) -> ServerRecording {
        let endpoint = try activeEndpoint()
        let source = RecordingPlaylistSource(playlist: playlist)
        guard Self.isRecordable(stream, in: source, on: endpoint) else { throw .unsupportedSource }
        let date = now()
        let liveProgramme = programme.flatMap {
            RecordingRequestPlanner.timing(of: $0, now: date) == .live ? $0 : nil
        }
        guard liveProgramme != nil || duration != nil else { throw .durationRequired }
        let channel = Self.channel(stream: stream, playlist: playlist)
        let target = try await createTarget(stream: stream, playlist: playlist, source: source, endpoint: endpoint)
        let plan: RecordingRequestPlanner.Plan? = if let duration, liveProgramme == nil {
            RecordingRequestPlanner.recordNow(target: target, channel: channel, duration: duration, now: date)
        } else {
            RecordingRequestPlanner.recordNow(
                target: target, channel: channel, programme: liveProgramme, now: date,
                padding: endpoint.kind.capabilities.padding
            )
        }
        guard let plan else { throw .durationRequired }
        return try await create(plan, endpoint: endpoint)
    }

    /// Schedules an upcoming `programme`, padded by Lume or by the server.
    @discardableResult
    func schedule(
        stream: LiveStream,
        playlist: Playlist,
        programme: RecordingRequestPlanner.Programme
    ) async throws(RecordingActionError) -> ServerRecording {
        let endpoint = try activeEndpoint()
        let source = RecordingPlaylistSource(playlist: playlist)
        guard Self.isRecordable(stream, in: source, on: endpoint) else { throw .unsupportedSource }
        let capabilities = endpoint.kind.capabilities
        guard Self.canSchedule(source.sourceType, with: capabilities) else { throw .scheduleUnsupported }
        let date = now()
        guard RecordingRequestPlanner.timing(of: programme, now: date) == .upcoming else {
            throw .programmeNotUpcoming
        }
        let channel = Self.channel(stream: stream, playlist: playlist)
        let target = try await createTarget(stream: stream, playlist: playlist, source: source, endpoint: endpoint)
        guard let plan = RecordingRequestPlanner.schedule(
            target: target, channel: channel, programme: programme, now: date, padding: capabilities.padding
        ) else { throw .programmeNotUpcoming }
        return try await create(plan, endpoint: endpoint)
    }

    private func create(
        _ plan: RecordingRequestPlanner.Plan,
        endpoint: RecordingServerEndpoint
    ) async throws(RecordingActionError) -> ServerRecording {
        let backend = makeBackend(endpoint)
        let recording = try await perform("create") { () async throws(RecordingServerError) in
            try await backend.createRecording(plan.request, idempotencyKey: plan.idempotencyKey)
        }
        upsert(recording)
        pollSoon()
        return recording
    }

    // MARK: - Targets

    /// What the server records from. A Dispatcharr stream UUID resolves
    /// through the server's channel list, off the main actor.
    private func createTarget(
        stream: LiveStream,
        playlist: Playlist,
        source: RecordingPlaylistSource,
        endpoint: RecordingServerEndpoint
    ) async throws(RecordingActionError) -> RecordingCreateTarget {
        switch endpoint.kind {
        case .lumeRecorder:
            return try await .streamURL(resolveStreamURL(stream: stream, playlist: playlist))
        case .dispatcharr:
            switch Self.dispatcharrLocator(stream, in: source, baseURL: endpoint.baseURL) {
            case nil:
                throw .unsupportedSource
            case let .channelID(id):
                return .dispatcharrChannel(id)
            case let .streamUUID(uuid):
                guard let backend = makeBackend(endpoint) as? any RecordingServerChannelResolving else {
                    throw .streamUnavailable
                }
                let id = try? await Self.offMain { () async throws(RecordingServerError) -> Int? in
                    await backend.channelID(forStreamUUID: uuid)
                }
                guard let id else { throw .streamUnavailable }
                return .dispatcharrChannel(id)
            }
        }
    }

    /// Exactly the URL Play would open. A Stalker placeholder is swapped for a
    /// fresh `create_link` URL here, at tap time — never sent as-is.
    private func resolveStreamURL(stream: LiveStream, playlist: Playlist) async throws(RecordingActionError) -> URL {
        guard let url = LiveStreamURLResolver.playbackURL(for: stream, playlist: playlist) else {
            throw .streamUnavailable
        }
        guard LiveStreamURLResolver.needsTapTimeResolution(url) else { return url }
        let resolved: URL?
        do {
            resolved = try await StalkerStreamResolver.resolve(url: url, playlist: playlist, using: resolveStalkerLink)
        } catch {
            let detail = (error as? StalkerError)?.logDescription ?? LogRedaction.describe(error)
            Logger.recording.error("Stalker create_link for a recording failed: \(detail, privacy: .public)")
            throw .streamUnavailable
        }
        guard let resolved else { throw .streamUnavailable }
        return resolved
    }

    private static func channel(stream: LiveStream, playlist: Playlist) -> RecordingRequestPlanner.Channel {
        RecordingRequestPlanner.Channel(
            name: stream.name,
            logoURL: stream.streamIcon.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            sourceRef: RecordingSourceRef(stream: stream, playlist: playlist)
        )
    }
}
