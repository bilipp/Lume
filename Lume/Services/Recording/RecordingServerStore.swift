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

    private(set) var recordings: [ServerRecording] = []
    private(set) var status: RecordingServerStatus?
    private(set) var reachability: Reachability = .unknown
    private(set) var isRefreshing = false
    /// What the signed-in account may do, once read from the server; `nil`
    /// until then, when the backend kind's own capabilities apply.
    private(set) var accountCapabilities: RecordingServerCapabilities?

    @ObservationIgnored let configService: RecordingServerConfigService
    @ObservationIgnored let makeBackend: BackendFactory
    @ObservationIgnored private let isFeatureUnlocked: @MainActor (PremiumFeature) -> Bool
    @ObservationIgnored let resolveStalkerLink: StalkerLinkResolver
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let pendingPollInterval: Duration
    @ObservationIgnored private let idlePollInterval: Duration
    @ObservationIgnored private let revokeTimeout: Duration
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
        revokeTimeout: Duration = .seconds(5),
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
        self.revokeTimeout = revokeTimeout
        self.progressDefaults = progressDefaults
    }

    // MARK: - Availability

    var isPaired: Bool {
        configService.isPaired
    }

    /// The paired server, whether or not Lume Pro is active.
    var pairedEndpoint: RecordingServerEndpoint? {
        configService.activeServer?.endpoint
    }

    var isUnlocked: Bool {
        isFeatureUnlocked(.recordingServer)
    }

    var isPolling: Bool {
        pollTask != nil
    }

    // MARK: - Lookup

    /// The recording capturing a channel right now — what turns the channel's
    /// Record into Stop Recording. A schedule for later tonight doesn't.
    func activeRecording(forSourceRef sourceRef: RecordingSourceRef) -> ServerRecording? {
        RecordingRequestPlanner.activeRecording(for: sourceRef, now: now(), in: recordings)
    }

    func activeRecording(for stream: LiveStream, in playlist: Playlist) -> ServerRecording? {
        activeRecording(forSourceRef: RecordingSourceRef(stream: stream, playlist: playlist))
    }

    /// The pending recording of one guide programme on a channel — what turns
    /// its Record or Schedule Recording into Stop or Cancel.
    func pendingRecording(
        forSourceRef sourceRef: RecordingSourceRef,
        programme: RecordingRequestPlanner.Programme?
    ) -> ServerRecording? {
        RecordingRequestPlanner.pendingRecording(for: sourceRef, programme: programme, now: now(), in: recordings)
    }

    // MARK: - Pairing

    /// Unauthenticated identity check of the server at `baseURL`: before
    /// pairing, and for the paired server's version line.
    func serverInfo(baseURL: URL) async throws(RecordingServerError) -> ServerIdentity {
        try await serverInfo(for: RecordingServerEndpoint(kind: .lumeRecorder, baseURL: baseURL, token: nil))
    }

    /// The identity of a paired server, through its own kind of backend.
    func serverInfo(for endpoint: RecordingServerEndpoint) async throws(RecordingServerError) -> ServerIdentity {
        let backend = makeBackend(endpoint)
        return try await Self.offMain { () async throws(RecordingServerError) in try await backend.serverInfo() }
    }

    /// Exchanges the one-time `code` with the server at `baseURL` for a token
    /// and stores the pairing (synced to every device on the account).
    @discardableResult
    func pair(baseURL: URL, code: String) async throws(RecordingServerError) -> RecordingServerConfig {
        let kind = RecordingServerKind.lumeRecorder
        guard let backend = makeBackend(RecordingServerEndpoint(kind: kind, baseURL: baseURL, token: nil))
            as? any RecordingServerDevicePairing
        else { throw .unsupportedBackend }
        let deviceName = Self.pairingDeviceName
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: RecordingServerPairing
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
        await adoptPairing(config, capabilities: nil)
        return config
    }

    /// Starts mirroring a pairing just saved, keeping the account capabilities
    /// read while pairing instead of asking the server again.
    func adoptPairing(_ config: RecordingServerConfig, capabilities: RecordingServerCapabilities?) async {
        resetMirroredState()
        loadedEndpoint = config.endpoint
        accountCapabilities = capabilities
        await reload()
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
    func pollSoon() {
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
    /// A server without a status endpoint gets its counts from every reload
    /// of the recordings instead, so its status can never fail on its own.
    func refreshStatus() async {
        guard let endpoint = prepareEndpoint() else { return }
        let backend = makeBackend(endpoint)
        guard backend.capabilities.hasStatusEndpoint else { return }
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
        let readCapabilities = accountCapabilities == nil
        let newRecordings: [ServerRecording]
        let capabilities: RecordingServerCapabilities?
        do {
            (newRecordings, capabilities) = try await Self.offMain { () async throws(RecordingServerError) in
                // A failed read is retried on the next refresh.
                async let capabilities = readCapabilities ? try? backend.accountCapabilities() : nil
                let recordings = try await backend.recordings()
                return await (recordings, capabilities)
            }
            guard loadedEndpoint == endpoint else { return }
            lastRefresh = .now
            if recordings != newRecordings { recordings = newRecordings }
            if reachability != .reachable { reachability = .reachable }
            if !backend.capabilities.hasStatusEndpoint {
                let counted = RecordingServerStatus(counting: newRecordings)
                if status != counted { status = counted }
            }
        } catch {
            noteRefreshFailure(error, endpoint: endpoint)
            return
        }
        if let capabilities, accountCapabilities == nil { accountCapabilities = capabilities }
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

    // MARK: - Stop / delete

    /// Cancels a scheduled recording or ends a running one.
    @discardableResult
    func stop(id: RecordingID) async throws(RecordingActionError) -> ServerRecording {
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
    func delete(id: RecordingID) async throws(RecordingActionError) {
        let backend = try makeBackend(activeEndpoint())
        do {
            try await perform("delete") { () async throws(RecordingServerError) in
                try await backend.deleteRecording(id: id)
            }
        } catch .server(.notFound) {
            // Already gone.
        }
        recordings.removeAll { $0.id == id }
        RecordingProgressStore.remove(
            recordingID: RecordingProgressStore.identifier(for: id, namespace: configService.activeServer?.progressNamespace),
            defaults: progressDefaults
        )
    }

    // MARK: - Playback

    /// A playable item for `recording`, backed by a short-lived URL. An
    /// in-progress recording plays from its start; a finished one resumes
    /// where this device left it.
    func playbackMedia(for recording: ServerRecording) async throws(RecordingActionError) -> PlayableMedia {
        let backend = try makeBackend(activeEndpoint())
        let namespace = configService.activeServer?.progressNamespace
        let recordingID = recording.id
        let playback = try await perform("playback") { () async throws(RecordingServerError) in
            try await backend.playback(id: recordingID)
        }
        return .recording(
            recording, playback: playback, progressNamespace: namespace,
            startTime: RecordingProgressStore.resumePosition(for: recording, namespace: namespace, defaults: progressDefaults),
            now: now()
        )
    }

    // MARK: - Helpers

    func activeEndpoint() throws(RecordingActionError) -> RecordingServerEndpoint {
        guard isUnlocked else { throw .premiumRequired }
        guard let endpoint = configService.activeServer?.endpoint else { throw .notPaired }
        return endpoint
    }

    /// Runs one server call off the main actor and folds its failure into the
    /// store's reachability.
    func perform<T: Sendable>(
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
    nonisolated static func offMain<T: Sendable>(
        _ operation: @Sendable () async throws(RecordingServerError) -> T
    ) async throws(RecordingServerError) -> T {
        try await operation()
    }

    func upsert(_ recording: ServerRecording) {
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
        accountCapabilities = nil
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

// MARK: - Removal

extension RecordingServerStore {
    /// What removing a server managed on the server itself.
    nonisolated enum Removal: Equatable {
        /// Revoked, already gone on the server, or nothing to revoke.
        case revoked
        /// Not reached in time, or refused: the server may still list this device.
        case revokeFailed
    }

    /// Forgets a server on every device on the account. First asks the server,
    /// once and briefly, to revoke the pairing; the config row goes whatever it
    /// answers, so an unreachable server never strands it. Recordings and
    /// schedules on the server are left untouched.
    @discardableResult
    func removeServer(id: UUID) async -> Removal {
        guard let config = configService.server(id: id) else { return .revoked }
        let removal = await revoke(config)
        forget(id: id)
        return removal
    }

    /// Forgets a server config without contacting it: the Other Servers rows,
    /// which this build can't talk to.
    func forget(id: UUID) {
        configService.delete(id: id)
        if configService.activeServer?.endpoint != loadedEndpoint {
            resetMirroredState()
        }
    }

    private func revoke(_ config: RecordingServerConfig) async -> Removal {
        guard let endpoint = config.endpoint, let deviceID = config.deviceID else { return .revoked }
        guard let backend = makeBackend(endpoint) as? any RecordingServerDevicePairing,
              backend.capabilities.deviceRevoke
        else { return .revoked }
        let timeout = revokeTimeout
        do {
            try await Self.offMain { () async throws(RecordingServerError) in
                try await Self.withTimeout(timeout) { () async throws(RecordingServerError) in
                    try await backend.unpair(deviceID: deviceID)
                }
            }
            return .revoked
        } catch .unauthorized, .notFound {
            // Already revoked on the server.
            return .revoked
        } catch {
            Logger.recording.error("Recording server revoke failed: \(error.logDescription, privacy: .public)")
            return .revokeFailed
        }
    }

    /// Fails with `.unreachable(.timedOut)` once `timeout` passes, cancelling
    /// `operation`.
    private nonisolated static func withTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws(RecordingServerError) -> Void
    ) async throws(RecordingServerError) {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RecordingServerError.unreachable(.timedOut)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            throw RecordingServerError(error)
        }
    }
}
