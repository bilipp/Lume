//
//  RecordingServerStore.swift
//  Lume
//
//  The in-memory face of the paired recording server: its recordings, disk
//  status and reachability, plus every action the UI takes on it. Recordings
//  are never persisted — the server is the source of truth and the store only
//  mirrors it while a surface that needs it is on screen.
//
//  Network calls run off the main actor and never block launch, playback or
//  sync; the only SwiftData writes are pairing changes through
//  `RecordingServerConfigService`, which happen from Settings, never during
//  playback.
//

import Foundation
import LumeRecorderKit
import Observation
import os
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
@Observable
final class RecordingServerStore {
    static let shared = RecordingServerStore()

    typealias BackendFactory = (RecordingServerEndpoint) -> any RecordingServerBackend
    typealias StalkerLinkResolver = StalkerStreamResolver.LinkResolver

    enum Reachability: Equatable {
        case unknown
        case reachable
        case unreachable(RecordingServerError)

        /// The server rejected the stored token; the user has to pair again.
        var needsRepairing: Bool {
            self == .unreachable(.unauthorized)
        }
    }

    private(set) var recordings: [Recording] = []
    private(set) var status: ServerStatus?
    private(set) var reachability: Reachability = .unknown
    private(set) var isRefreshing = false

    @ObservationIgnored private let configService: RecordingServerConfigService
    @ObservationIgnored private let makeBackend: BackendFactory
    @ObservationIgnored private let isFeatureUnlocked: @MainActor (PremiumFeature) -> Bool
    @ObservationIgnored private let resolveStalkerLink: StalkerLinkResolver
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pendingPollInterval: Duration
    @ObservationIgnored private let idlePollInterval: Duration
    @ObservationIgnored private let progressDefaults: UserDefaults

    @ObservationIgnored private var observerCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    /// The server the mirrored state belongs to; a different one resets it.
    @ObservationIgnored private var loadedEndpoint: RecordingServerEndpoint?

    init(
        configService: RecordingServerConfigService? = nil,
        makeBackend: @escaping BackendFactory = { $0.makeBackend() },
        isFeatureUnlocked: (@MainActor (PremiumFeature) -> Bool)? = nil,
        resolveStalkerLink: @escaping StalkerLinkResolver = StalkerStreamResolver.portalLinkResolver,
        now: @escaping () -> Date = Date.init,
        pendingPollInterval: Duration = .seconds(10),
        idlePollInterval: Duration = .seconds(60),
        progressDefaults: UserDefaults = .standard
    ) {
        // `.shared` is resolved here, not as a default argument: default
        // arguments are evaluated in the caller's isolation.
        self.configService = configService ?? .shared
        self.makeBackend = makeBackend
        self.isFeatureUnlocked = isFeatureUnlocked ?? { _ in PremiumManager.shared.isPremium }
        self.resolveStalkerLink = resolveStalkerLink
        self.now = now
        self.pendingPollInterval = pendingPollInterval
        self.idlePollInterval = idlePollInterval
        self.progressDefaults = progressDefaults
    }

    // MARK: - Availability

    var isPaired: Bool {
        configService.isPaired
    }

    var isUnlocked: Bool {
        isFeatureUnlocked(.recordingServer)
    }

    /// Whether a Record action belongs on this playlist's channels at all.
    /// Paired-but-lapsed still shows it, behind the crown.
    func supportsRecording(_ sourceType: PlaylistSourceType) -> Bool {
        isPaired && sourceType.supportsRecording
    }

    func supportsScheduling(_ sourceType: PlaylistSourceType) -> Bool {
        isPaired && sourceType.supportsRecordingSchedule
    }

    var isPolling: Bool {
        pollTask != nil
    }

    // MARK: - Lookup

    /// The recording capturing a channel right now — what turns the channel's
    /// Record into Stop Recording. A schedule for later tonight doesn't.
    func activeRecording(forSourceRef sourceRef: RecordingSourceRef) -> Recording? {
        RecordingRequestPlanner.activeRecording(for: sourceRef, now: now(), in: recordings)
    }

    func activeRecording(for stream: LiveStream, in playlist: Playlist) -> Recording? {
        activeRecording(forSourceRef: RecordingSourceRef(stream: stream, playlist: playlist))
    }

    /// Running, or a schedule whose window has opened: Stop rather than Cancel.
    func isCapturing(_ recording: Recording) -> Bool {
        RecordingRequestPlanner.isCapturing(recording, now: now())
    }

    /// The pending recording of one guide programme on a channel — what turns
    /// its Record or Schedule Recording into Stop or Cancel.
    func pendingRecording(
        forSourceRef sourceRef: RecordingSourceRef,
        programme: RecordingRequestPlanner.Programme?
    ) -> Recording? {
        RecordingRequestPlanner.pendingRecording(for: sourceRef, programme: programme, now: now(), in: recordings)
    }

    // MARK: - Pairing

    /// Unauthenticated identity check of the server at `baseURL`: before
    /// pairing, and for the paired server's version line.
    func serverInfo(baseURL: URL) async throws(RecordingServerError) -> ServerInfo {
        let backend = makeBackend(RecordingServerEndpoint(kind: .lumeRecorder, baseURL: baseURL, token: nil))
        return try await Self.offMain { () async throws(RecordingServerError) in try await backend.serverInfo() }
    }

    /// Exchanges the one-time `code` with the server at `baseURL` for a token
    /// and stores the pairing (synced to every device on the account).
    @discardableResult
    func pair(baseURL: URL, code: String) async throws(RecordingServerError) -> RecordingServerConfig {
        let kind = RecordingServerKind.lumeRecorder
        let backend = makeBackend(RecordingServerEndpoint(kind: kind, baseURL: baseURL, token: nil))
        let deviceName = Self.pairingDeviceName
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: PairResponse
        do {
            response = try await Self.offMain { () async throws(RecordingServerError) in
                try await backend.pair(code: trimmedCode, deviceName: deviceName)
            }
        } catch {
            Logger.recording.error("Recording server pairing failed: \(error.logDescription, privacy: .public)")
            throw error
        }
        guard let config = configService.savePairing(response, kind: kind, baseURL: baseURL) else {
            throw .invalidResponse
        }
        Logger.recording.log("Paired with a recording server")
        resetMirroredState()
        await reload()
        return config
    }

    /// Revokes this pairing on the server, then forgets it everywhere. A token
    /// the server already rejects still lets the row go; an unreachable server
    /// keeps it so the user can retry or remove it outright.
    func unpair(id: UUID) async throws(RecordingServerError) {
        guard let config = configService.server(id: id) else { return }
        if let endpoint = config.endpoint, let deviceID = config.deviceID {
            let backend = makeBackend(endpoint)
            do {
                try await Self.offMain { () async throws(RecordingServerError) in
                    try await backend.unpair(deviceID: deviceID)
                }
            } catch .unauthorized, .notFound {
                // Already revoked on the server.
            } catch {
                Logger.recording.error("Recording server unpair failed: \(error.logDescription, privacy: .public)")
                throw error
            }
        }
        remove(id: id)
    }

    /// Forgets a server config without contacting it. Anything scheduled on
    /// the server is left untouched.
    func remove(id: UUID) {
        configService.delete(id: id)
        if configService.activeServer?.endpoint != loadedEndpoint {
            resetMirroredState()
        }
    }

    // MARK: - Polling

    /// Call while a surface that shows recording state is visible; balanced by
    /// `endObserving()`. Polls every 10 s while anything is pending, else 60 s.
    func beginObserving() {
        observerCount += 1
        if observerCount == 1 {
            startPolling(initialDelay: timeUntilNextPoll())
        }
    }

    func endObserving() {
        guard observerCount > 0 else { return }
        observerCount -= 1
        if observerCount == 0 {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// `initialDelay` postpones the first refresh: the rest of the current
    /// interval when the last refresh is still within it, so a surface that
    /// appears and disappears repeatedly doesn't refresh on every appearance.
    private func startPolling(initialDelay: Duration?) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            if let initialDelay {
                do {
                    try await Task.sleep(for: initialDelay)
                } catch {
                    return
                }
            }
            while !Task.isCancelled {
                guard let self else { return }
                await reload()
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    private var pollInterval: Duration {
        recordings.contains { $0.status.isPending } ? pendingPollInterval : idlePollInterval
    }

    private func timeUntilNextPoll() -> Duration? {
        guard let lastRefresh else { return nil }
        let remaining = pollInterval - lastRefresh.duration(to: .now)
        return remaining > .zero ? remaining : nil
    }

    /// Restarts the poll cadence at the fast interval, so a just-created
    /// pending recording is followed closely. The action already upserted the
    /// server's answer, so the first refresh waits one interval.
    private func pollSoon() {
        if observerCount > 0 {
            startPolling(initialDelay: pendingPollInterval)
        }
    }

    // MARK: - Refresh

    /// A user-started refresh: the Refresh controls disable themselves while
    /// `isRefreshing`, which background polls leave alone.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await reload()
    }

    /// Refreshes only when the recordings are older than `maxAge`, for a
    /// control that reads them without polling (a channel's Record item).
    func refreshIfStale(maxAge: Duration) async {
        if let lastRefresh, lastRefresh.duration(to: .now) < maxAge { return }
        await reload()
    }

    /// Re-reads the disk status, which only the Recording Server settings show.
    func refreshStatus() async {
        guard let endpoint = prepareEndpoint() else { return }
        let backend = makeBackend(endpoint)
        do {
            let newStatus = try await Self.offMain { () async throws(RecordingServerError) in
                try await backend.status()
            }
            guard loadedEndpoint == endpoint else { return }
            if status != newStatus { status = newStatus }
        } catch {
            noteRefreshFailure(error, endpoint: endpoint)
        }
    }

    /// Re-reads the recordings from the active server. Not paired or not
    /// unlocked clears the mirrored state instead.
    private func reload() async {
        guard let endpoint = prepareEndpoint() else { return }
        let backend = makeBackend(endpoint)
        do {
            let newRecordings = try await Self.offMain { () async throws(RecordingServerError) in
                try await backend.recordings()
            }
            guard loadedEndpoint == endpoint else { return }
            lastRefresh = .now
            if recordings != newRecordings { recordings = newRecordings }
            if reachability != .reachable { reachability = .reachable }
        } catch {
            noteRefreshFailure(error, endpoint: endpoint)
        }
    }

    /// The active server's endpoint, resetting the mirrored state when it
    /// isn't the one loaded; `nil` when not paired or not unlocked.
    private func prepareEndpoint() -> RecordingServerEndpoint? {
        guard isUnlocked, let endpoint = configService.activeServer?.endpoint else {
            resetMirroredState()
            return nil
        }
        if endpoint != loadedEndpoint {
            resetMirroredState()
            loadedEndpoint = endpoint
        }
        return endpoint
    }

    private func noteRefreshFailure(_ error: any Error, endpoint: RecordingServerEndpoint) {
        guard loadedEndpoint == endpoint else { return }
        let mapped = RecordingServerError(error)
        guard mapped != .cancelled else { return }
        if reachability != .unreachable(mapped) { reachability = .unreachable(mapped) }
        Logger.recording.error("Recording server refresh failed: \(mapped.logDescription, privacy: .public)")
    }

    // MARK: - Record

    /// Starts recording `stream` now: until the airing `programme` ends plus
    /// the post-roll, or for `duration` when no programme is on air.
    @discardableResult
    func recordNow(
        stream: LiveStream,
        playlist: Playlist,
        programme: RecordingRequestPlanner.Programme?,
        duration: RecordingRequestPlanner.FallbackDuration? = nil
    ) async throws(RecordingActionError) -> Recording {
        let endpoint = try activeEndpoint()
        guard playlist.sourceType.supportsRecording else { throw .unsupportedSource }
        let date = now()
        let liveProgramme = programme.flatMap {
            RecordingRequestPlanner.timing(of: $0, now: date) == .live ? $0 : nil
        }
        guard liveProgramme != nil || duration != nil else { throw .durationRequired }
        let channel = Self.channel(stream: stream, playlist: playlist)
        let streamURL = try await resolveStreamURL(stream: stream, playlist: playlist)
        let plan: RecordingRequestPlanner.Plan? = if let duration, liveProgramme == nil {
            RecordingRequestPlanner.recordNow(streamURL: streamURL, channel: channel, duration: duration, now: date)
        } else {
            RecordingRequestPlanner.recordNow(streamURL: streamURL, channel: channel, programme: liveProgramme, now: date)
        }
        guard let plan else { throw .durationRequired }
        return try await create(plan, endpoint: endpoint)
    }

    /// Schedules an upcoming `programme` with the fixed pre- and post-roll.
    @discardableResult
    func schedule(
        stream: LiveStream,
        playlist: Playlist,
        programme: RecordingRequestPlanner.Programme
    ) async throws(RecordingActionError) -> Recording {
        let endpoint = try activeEndpoint()
        guard playlist.sourceType.supportsRecording else { throw .unsupportedSource }
        guard playlist.sourceType.supportsRecordingSchedule else { throw .scheduleUnsupported }
        let date = now()
        guard RecordingRequestPlanner.timing(of: programme, now: date) == .upcoming else {
            throw .programmeNotUpcoming
        }
        let channel = Self.channel(stream: stream, playlist: playlist)
        let streamURL = try await resolveStreamURL(stream: stream, playlist: playlist)
        guard let plan = RecordingRequestPlanner.schedule(
            streamURL: streamURL, channel: channel, programme: programme, now: date
        ) else { throw .programmeNotUpcoming }
        return try await create(plan, endpoint: endpoint)
    }

    private func create(
        _ plan: RecordingRequestPlanner.Plan,
        endpoint: RecordingServerEndpoint
    ) async throws(RecordingActionError) -> Recording {
        let backend = makeBackend(endpoint)
        let recording = try await perform("create") { () async throws(RecordingServerError) in
            try await backend.createRecording(plan.request, idempotencyKey: plan.idempotencyKey)
        }
        upsert(recording)
        pollSoon()
        return recording
    }

    // MARK: - Stop / delete

    /// Cancels a scheduled recording or ends a running one.
    @discardableResult
    func stop(id: UUID) async throws(RecordingActionError) -> Recording {
        let backend = try makeBackend(activeEndpoint())
        let recording = try await perform("stop") { () async throws(RecordingServerError) in
            try await backend.stopRecording(id: id)
        }
        upsert(recording)
        pollSoon()
        return recording
    }

    /// Deletes a recording and its media. One the server no longer has counts
    /// as deleted.
    func delete(id: UUID) async throws(RecordingActionError) {
        let backend = try makeBackend(activeEndpoint())
        do {
            try await perform("delete") { () async throws(RecordingServerError) in
                try await backend.deleteRecording(id: id)
            }
        } catch .server(.notFound) {
            // Already gone.
        }
        recordings.removeAll { $0.id == id }
        RecordingProgressStore.remove(recordingID: RecordingProgressStore.identifier(for: id), defaults: progressDefaults)
    }

    // MARK: - Playback

    /// A playable item for `recording`, backed by a short-lived signed URL. An
    /// in-progress recording plays from its start; a finished one resumes
    /// where this device left it.
    func playbackMedia(for recording: Recording) async throws(RecordingActionError) -> PlayableMedia {
        let backend = try makeBackend(activeEndpoint())
        let id = recording.id
        let grant = try await perform("playback") { () async throws(RecordingServerError) in
            try await backend.playbackGrant(id: id)
        }
        return .recording(
            recording, grant: grant,
            startTime: RecordingProgressStore.resumePosition(for: recording, defaults: progressDefaults),
            now: now()
        )
    }

    // MARK: - Helpers

    private func activeEndpoint() throws(RecordingActionError) -> RecordingServerEndpoint {
        guard isUnlocked else { throw .premiumRequired }
        guard let endpoint = configService.activeServer?.endpoint else { throw .notPaired }
        return endpoint
    }

    /// Runs one server call off the main actor and folds its failure into the
    /// store's reachability.
    private func perform<T: Sendable>(
        _ action: StaticString,
        _ operation: @Sendable () async throws(RecordingServerError) -> T
    ) async throws(RecordingActionError) -> T {
        do {
            let value = try await Self.offMain(operation)
            reachability = .reachable
            return value
        } catch {
            switch error {
            case .unreachable, .unauthorized:
                reachability = .unreachable(error)
            default:
                break
            }
            let name = "\(action)"
            Logger.recording.error("Recording server \(name, privacy: .public) failed: \(error.logDescription, privacy: .public)")
            throw .server(error)
        }
    }

    @concurrent
    private nonisolated static func offMain<T: Sendable>(
        _ operation: @Sendable () async throws(RecordingServerError) -> T
    ) async throws(RecordingServerError) -> T {
        try await operation()
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

    private func upsert(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.append(recording)
        }
    }

    private func resetMirroredState() {
        loadedEndpoint = nil
        lastRefresh = nil
        recordings = []
        status = nil
        reachability = .unknown
    }

    /// How this device appears in the server's device list. The token syncs,
    /// so whichever device pairs names the shared pairing.
    private static var pairingDeviceName: String {
        #if os(macOS)
            let name = Host.current().localizedName ?? "Mac"
        #else
            let name = UIDevice.current.name
        #endif
        return "Lume – \(name)"
    }
}

extension RecordingRequestPlanner.Programme {
    init(listing: EPGListing) {
        self.init(
            title: listing.title,
            description: listing.listingDescription,
            start: listing.start,
            end: listing.end
        )
    }
}
