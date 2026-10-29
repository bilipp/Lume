//
//  DispatcharrBackend.swift
//  Lume
//
//  `RecordingServerBackend` over a Dispatcharr server's DVR. Lume signs in
//  with the user's API key or username and password (never a pairing code)
//  and never revokes anything on the server. Dispatcharr owns padding: a
//  recording is created at the programme's own times and the server adds its
//  pre/post offsets.
//

import Foundation

nonisolated struct DispatcharrBackend: RecordingServerChannelResolving {
    /// The server has no name of its own; the address is shown beside this.
    static let serverName = "Dispatcharr"

    /// A player keeps sending the playback credential for as long as it plays,
    /// so a JWT about to expire is refreshed before it is handed out.
    static let playbackValidity: TimeInterval = 15 * 60

    let client: DispatcharrClient
    private let channels: DispatcharrChannelDirectory
    private let channelKey: DispatcharrChannelDirectory.Key?
    private let now: @Sendable () -> Date

    var kind: RecordingServerKind {
        .dispatcharr
    }

    init(
        baseURL: URL,
        credential: DispatcharrCredential?,
        session: URLSession = .recordingServer,
        tokens: DispatcharrTokenCache = .shared,
        channels: DispatcharrChannelDirectory = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        client = DispatcharrClient(baseURL: baseURL, credential: credential, session: session, tokens: tokens, now: now)
        self.channels = channels
        channelKey = credential.map { DispatcharrChannelDirectory.Key(baseURL: baseURL, user: $0.identityUser) }
        self.now = now
    }

    // MARK: - Server

    /// Unauthenticated: the version needs no credential. The id is derived from
    /// the address and account, so every device signed in to the same account
    /// on the same server gets the same one.
    func serverInfo() async throws(RecordingServerError) -> ServerIdentity {
        let version: DispatcharrVersion
        do {
            version = try await client.version()
        } catch .notFound {
            throw .invalidResponse
        }
        guard !version.version.isEmpty else { throw .invalidResponse }
        let id = RecordingServerIdentity.uuid(
            kind: .dispatcharr,
            baseURL: client.baseURL,
            user: client.credential?.identityUser ?? ""
        )
        return ServerIdentity(id: id, name: Self.serverName, version: version.version)
    }

    func accountCapabilities() async throws(RecordingServerError) -> RecordingServerCapabilities {
        var capabilities = capabilities
        switch try await client.currentUser().dvrAccess {
        case .none:
            throw .forbidden
        case .view:
            capabilities.readOnly = true
        case .manage:
            capabilities.readOnly = false
        }
        return capabilities
    }

    // MARK: - Recordings

    func recordings() async throws(RecordingServerError) -> [ServerRecording] {
        async let directory = channelSnapshot()
        let list = try await client.recordings()
        let snapshot = await directory
        let date = now()
        return list.map { serverRecording($0, channels: snapshot, now: date) }
    }

    /// Sends the request's times unpadded with the programme alongside, so the
    /// server pads and its rules see the programme. A fixed-duration
    /// record-now has no programme, so it goes without one and isn't padded. Dispatcharr has no
    /// idempotency keys: the key travels in `custom_properties`, and a re-send
    /// whose first attempt landed returns that recording instead of a second.
    func createRecording(
        _ request: RecordingCreateRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> ServerRecording {
        guard case let .dispatcharrChannel(channelID) = request.target else { throw .invalidRequest }
        async let snapshot = channelSnapshot()
        let landed = try await client.recordings().first(where: { $0.properties.requestID == idempotencyKey })
        let directory = await snapshot
        if let landed {
            return serverRecording(landed, channels: directory, now: now())
        }
        let body = DispatcharrRecordingCreate(
            channelID: channelID,
            start: request.start,
            end: request.end,
            sourceRef: request.sourceRef,
            requestID: idempotencyKey,
            program: request.programme.map {
                DispatcharrProgram(
                    title: request.title,
                    description: request.programmeDescription,
                    start: $0.start,
                    end: $0.end
                )
            }
        )
        let created = try await client.createRecording(body)
        return serverRecording(created, channels: directory, now: now())
    }

    /// A recording that hasn't started is cancelled (deleted); a running one is
    /// stopped and keeps what it captured. One that already ended is returned
    /// as is: the server answers a stop on it with 409.
    func stopRecording(id: RecordingID) async throws(RecordingServerError) -> ServerRecording {
        let serverID = try Self.serverID(id)
        async let directory = channelSnapshot()
        let raw = try await client.recording(id: serverID)
        var recording = await serverRecording(raw, channels: directory, now: now())
        switch recording.status {
        case .scheduled:
            try await client.deleteRecording(id: serverID)
            recording.status = .cancelled
        case .recording:
            try await client.stopRecording(id: serverID)
            recording.status = .completed
            recording.isPartial = true
            recording.finishedAt = now()
        case .completed, .failed, .cancelled, .unknown:
            break
        }
        return recording
    }

    func deleteRecording(id: RecordingID) async throws(RecordingServerError) {
        try await client.deleteRecording(id: Self.serverID(id))
    }

    /// A running recording plays from its live HLS playlist, a finished one
    /// from its MKV, both authorized by header. VLC can't send headers; in
    /// password mode `DispatcharrPlaybackAuth` folds the Bearer JWT into
    /// `?token=`, which the server propagates to every segment.
    func playback(id: RecordingID) async throws(RecordingServerError) -> RecordingPlayback {
        let serverID = try Self.serverID(id)
        let client = client
        async let authorization = client.playbackAuthorization(validFor: Self.playbackValidity)
        let recording = try await serverRecording(client.recording(id: serverID), channels: .empty, now: now())
        let url: URL
        switch recording.status {
        case .scheduled:
            throw .notPlayableYet
        case .cancelled:
            throw .notFound
        case .recording:
            url = client.hlsURL(id: serverID)
        case .completed, .failed, .unknown:
            url = client.fileURL(id: serverID)
        }
        do {
            return try await RecordingPlayback(url: url, httpHeaders: authorization.headers)
        } catch {
            // `async let` erases the typed error.
            throw RecordingServerError(error)
        }
    }

    func channelID(forStreamUUID uuid: UUID) async -> Int? {
        await channelSnapshot().idsByUUID[uuid]
    }

    // MARK: - Mapping

    private func channelSnapshot() async -> DispatcharrChannelDirectory.Snapshot {
        guard let key = channelKey else { return .empty }
        let client = client
        return await channels.snapshot(for: key, now: now()) { () async throws(RecordingServerError) in
            try await client.channels()
        }
    }

    private func serverRecording(
        _ recording: DispatcharrRecording,
        channels: DispatcharrChannelDirectory.Snapshot,
        now: Date
    ) -> ServerRecording {
        let channel = recording.channelID.flatMap { channels.byID[$0] }
        let logoID = channel?.logoID ?? recording.properties.posterLogoID
        return Self.serverRecording(
            recording,
            channelName: channel?.name,
            channelLogoURL: logoID.map(client.logoURL(id:)),
            now: now
        )
    }

    static func serverRecording(
        _ recording: DispatcharrRecording,
        channelName: String?,
        channelLogoURL: URL?,
        now: Date
    ) -> ServerRecording {
        let properties = recording.properties
        let state = state(of: recording, now: now)
        let title = properties.program?.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? channelName
            ?? String(localized: "Recording")
        return ServerRecording(
            id: RecordingID(rawValue: String(recording.id)),
            title: title,
            channelName: channelName,
            channelLogoURL: channelLogoURL,
            programmeDescription: properties.program?.description,
            sourceRef: properties.sourceRef,
            start: recording.start,
            end: recording.end,
            status: state.status,
            failureReason: state.failureReason,
            createdAt: recording.start,
            startedAt: properties.startedAt,
            finishedAt: properties.endedAt ?? properties.stoppedAt,
            sizeBytes: properties.bytesWritten,
            isPartial: state.isPartial,
            programmeEnd: properties.program?.end
        )
    }

    private struct State {
        var status: ServerRecordingStatus
        var isPartial = false
        var failureReason: String?
    }

    /// `custom_properties.status` as the app's status. A recording has none
    /// until its task starts; one whose window passed without it never ran,
    /// for no reason Lume can word. Failure reasons are the codes the library
    /// already words.
    private static func state(of recording: DispatcharrRecording, now: Date) -> State {
        let properties = recording.properties
        let hasMedia = (properties.bytesWritten ?? 0) > 0 || properties.remuxSuccess == true
        switch properties.status {
        case nil, "scheduled":
            return State(status: recording.end > now ? .scheduled : .failed)
        case "recording":
            return State(status: .recording)
        case "completed":
            return State(status: .completed)
        case "stopped":
            // Stopped before its task connected: nothing was captured.
            if properties.startedAt == nil, !hasMedia { return State(status: .cancelled) }
            return State(status: .completed, isPartial: true)
        case "interrupted":
            if hasMedia { return State(status: .completed, isPartial: true) }
            let noData = properties.interruptedReason?.hasPrefix("no_stream_data") == true
            return State(status: .failed, failureReason: noData ? "source_unavailable" : "interrupted")
        case "failed":
            return State(status: .failed)
        case "cancelled":
            return State(status: .cancelled)
        case let .some(raw):
            return State(status: .unknown(raw))
        }
    }

    /// An id Dispatcharr can't have minted reads as a recording it doesn't have.
    private static func serverID(_ id: RecordingID) throws(RecordingServerError) -> Int {
        guard let value = Int(id.rawValue) else { throw .notFound }
        return value
    }
}

/// Server only: the credential is a secret and the address a LAN location.
nonisolated extension DispatcharrBackend: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "DispatcharrBackend(\(client))"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
