//
//  HueSyncController.swift
//  Lume
//
//  Runs one Philips Hue light-sync session: snapshot the area's lights,
//  persist that snapshot, open the area over CLIP v2, connect the stream and
//  feed it ~50 packets a second from whichever `HueFrameSource` is current.
//  Stopping closes the stream, closes the area, restores the lights and only
//  then forgets the snapshot. Nothing is retried; state is published on events
//  only, never per frame.
//

import Foundation
import Observation
import os

nonisolated enum HueSyncError: Error, Hashable {
    case bridge(HueBridgeError)
    case stream(HueStreamTransportError)
    /// The chosen area has no channels the stream can address.
    case unsupportedArea
}

nonisolated enum HueSyncState: Hashable {
    case idle
    case connecting
    case streaming
    /// Streaming, holding the last colours, because the current source has
    /// no frames to give.
    case unavailable(HueFrameUnavailableReason)
    /// Another app or a Sync Box streams to the area; it is left alone.
    case areaInUse
    case error(HueSyncError)
}

struct HueSyncDependencies {
    var pairedBridge: () -> (address: HueBridgeAddress, secrets: HueBridgeSecrets)?
    var makeClient: (HueBridgeAddress, HueBridgeSecrets) -> HueBridgeClient?
    var makeTransport: (HueBridgeAddress, HueBridgeCredentials) -> (any HueStreamTransport)?
    var defaults: UserDefaults
    /// Seconds on a monotonic clock.
    var now: () -> Double
    /// Nil runs no tick loop; the caller drives `tick()`.
    var tickInterval: Duration?
}

#if os(tvOS)
    extension HueSyncDependencies {
        static var live: HueSyncDependencies {
            let store = HueCredentialStore()
            let clock = ContinuousClock()
            let origin = clock.now
            return HueSyncDependencies(
                pairedBridge: { store.pairedBridgeAndSecrets() },
                makeClient: { HueBridgeClient(bridge: $0, secrets: $1) },
                makeTransport: { DTLSHueStreamTransport(host: $0.host, credentials: $1) },
                defaults: .standard,
                now: {
                    let elapsed = clock.now - origin
                    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
                },
                tickInterval: .milliseconds(20)
            )
        }
    }
#endif

@Observable
final class HueSyncController {
    #if os(tvOS)
        static let shared = HueSyncController(dependencies: .live)
    #endif

    private(set) var state: HueSyncState = .idle
    /// The registered source's standing reason it has no frames, whether or
    /// not a session runs.
    private(set) var sourceUnavailableReason: HueFrameUnavailableReason?
    /// The newest failure, for the diagnostic report; outlives the session.
    @ObservationIgnored private(set) var lastError: HueSyncError?

    @ObservationIgnored private let dependencies: HueSyncDependencies
    /// The registered source, which a session started later keeps.
    @ObservationIgnored private(set) weak var frameSource: (any HueFrameSource)?
    @ObservationIgnored private var session: Session?
    /// The last close or launch restore; a new session waits for it so it
    /// never snapshots lamps still showing the previous stream.
    @ObservationIgnored private var pendingClose: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(dependencies: HueSyncDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Session

    /// Opens a session, or retargets the running one. The returned task ends
    /// once the area is open and the stream is connecting, or setup failed.
    @discardableResult
    func start(
        source newSource: (any HueFrameSource)?,
        intensity: HueIntensity,
        reduceMotion: Bool
    ) -> Task<Void, Never> {
        guard intensity != .off else {
            setSource(newSource)
            stop()
            return Task {}
        }
        setSource(newSource)
        if let session {
            setIntensity(intensity)
            setReduceMotion(reduceMotion)
            return session.setup ?? Task {}
        }
        let session = Session(intensity: intensity, reduceMotion: reduceMotion)
        self.session = session
        state = .connecting
        let previous = pendingClose
        let setup = Task {
            await previous?.value
            await open(session)
        }
        session.setup = setup
        return setup
    }

    /// Ends the session: stream closed, area stopped, lights restored. The
    /// returned task ends once the lights are back.
    @discardableResult
    func stop() -> Task<Void, Never> {
        setSource(nil)
        return suspend()
    }

    /// Ends the session like `stop()` but keeps the registered source (its
    /// tap removed until the next frame is asked for), so the player can
    /// resume when the app comes back to the foreground.
    @discardableResult
    func suspend() -> Task<Void, Never> {
        frameSource?.detach()
        guard let session else { return pendingClose ?? Task {} }
        end(session, state: .idle)
        return pendingClose ?? Task {}
    }

    /// Swaps the frame source without touching the stream. The previous
    /// source's tap is removed.
    func setSource(_ newSource: (any HueFrameSource)?) {
        guard newSource !== frameSource else { return }
        frameSource?.detach()
        frameSource = newSource
        let reason = newSource?.unavailableReason
        if sourceUnavailableReason != reason { sourceUnavailableReason = reason }
    }

    /// Removes `oldSource` unless another source already replaced it; the
    /// engine that is going away may report after its successor registered.
    func clearSource(_ oldSource: any HueFrameSource) {
        guard oldSource === frameSource else { return }
        setSource(nil)
    }

    /// A paired bridge and a chosen entertainment area, from UserDefaults
    /// only; a session whose keys are gone ends itself in `open`.
    var isConfigured: Bool {
        PlayerSettings.Hue.entertainmentAreaID(in: dependencies.defaults) != nil
            && HueCredentialStore(defaults: dependencies.defaults).hasPairing
    }

    /// Opens a session for the registered source when Lume Pro, the saved
    /// setting and a configured area allow it, at the saved level.
    func startIfEligible(reduceMotion: Bool) {
        let defaults = dependencies.defaults
        guard !LumeApp.isTestOrPreviewHost,
              PremiumManager.shared.isPremium,
              PlayerSettings.Hue.isEnabled(in: defaults),
              isConfigured
        else { return }
        start(source: frameSource, intensity: PlayerSettings.Hue.intensity(in: defaults), reduceMotion: reduceMotion)
    }

    /// `.off` ends the session.
    func setIntensity(_ intensity: HueIntensity) {
        guard intensity != .off else {
            suspend()
            return
        }
        guard let session else { return }
        session.intensity = intensity
        session.sampler?.setIntensity(intensity)
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard let session else { return }
        session.reduceMotion = reduceMotion
        session.sampler?.setReduceMotion(reduceMotion)
    }

    /// Restores lamps a crash left in stream colours. Kept for later while the
    /// area still streams: that may be the crashed stream not yet timed out.
    @discardableResult
    func restoreLeftoverSnapshot() -> Task<Void, Never>? {
        let defaults = dependencies.defaults
        guard session == nil,
              let snapshot = PlayerSettings.Hue.restoreSnapshot(in: defaults),
              let paired = dependencies.pairedBridge(),
              let client = dependencies.makeClient(paired.address, paired.secrets)
        else { return nil }
        let areaID = PlayerSettings.Hue.entertainmentAreaID(in: defaults)
        let previous = pendingClose
        let task = Task {
            await previous?.value
            do throws(HueBridgeError) {
                if let areaID, try await client.entertainmentConfiguration(id: areaID).isStreaming {
                    return
                }
                try await client.restore(snapshot)
                PlayerSettings.Hue.clearRestoreSnapshot(in: defaults)
            } catch {
                self.lastError = .bridge(error)
                let reason = LogRedaction.describe(error)
                Logger.player.error("Hue leftover restore failed: \(reason, privacy: .public)")
            }
        }
        pendingClose = task
        return task
    }

    private func open(_ session: Session) async {
        guard !session.isEnded else { return }
        let defaults = dependencies.defaults
        guard let paired = dependencies.pairedBridge(),
              let areaID = PlayerSettings.Hue.entertainmentAreaID(in: defaults),
              let client = dependencies.makeClient(paired.address, paired.secrets)
        else {
            end(session, state: .idle)
            return
        }
        session.client = client
        session.areaID = areaID
        do {
            let area = try await client.entertainmentConfiguration(id: areaID)
            guard !session.isEnded else { return }
            guard !area.isStreaming else {
                end(session, state: .areaInUse)
                return
            }
            guard try await prepare(session, area: area, client: client) else { return }

            do {
                try await client.startStreaming(areaID: areaID)
            } catch .areaInUse {
                // Put back only what a crashed session left; this session
                // never touched the lamps.
                session.snapshot = nil
                if let leftover = session.leftoverSnapshot {
                    PlayerSettings.Hue.saveRestoreSnapshot(leftover, in: defaults)
                } else {
                    PlayerSettings.Hue.clearRestoreSnapshot(in: defaults)
                }
                end(session, state: .areaInUse)
                return
            }
            session.didStartStream = true
            guard !session.isEnded else { return }
            connect(session, to: paired)
        } catch {
            guard !session.isEnded else { return }
            let reason = LogRedaction.describe(error)
            Logger.player.error("Hue session setup failed: \(reason, privacy: .public)")
            end(session, state: .error(.bridge(error)))
        }
    }

    /// Captures and persists the area's lights, then builds the sampler.
    /// False when the session ended or the area can't be streamed.
    private func prepare(
        _ session: Session,
        area: HueEntertainmentConfiguration,
        client: HueBridgeClient
    ) async throws(HueBridgeError) -> Bool {
        let defaults = dependencies.defaults
        // `async let` loses the typed error, so each read is a `Result`.
        async let fetchedServices = Self.result { () async throws(HueBridgeError) in
            try await client.entertainmentServices()
        }
        async let fetchedLights = Self.result { () async throws(HueBridgeError) in
            try await client.lights()
        }
        let services = try await fetchedServices.get()
        let lights = try await fetchedLights.get()
        guard !session.isEnded else { return false }

        let captured = HueLightSnapshot(
            capturing: lights,
            lightIDs: area.lightIDs(entertainmentServices: services)
        )
        let leftover = PlayerSettings.Hue.restoreSnapshot(in: defaults)
        session.leftoverSnapshot = leftover
        let snapshot = Self.merging(leftover: leftover, captured)
        PlayerSettings.Hue.saveRestoreSnapshot(snapshot, in: defaults)
        session.snapshot = snapshot

        guard let sampler = HueFrameSampler(
            entertainmentConfigurationID: area.id,
            layout: HueChannelLayout(channels: area.channels),
            intensity: session.intensity,
            reduceMotion: session.reduceMotion
        ) else {
            end(session, state: .error(.unsupportedArea))
            return false
        }
        session.sampler = sampler
        return true
    }

    private static func result<Value>(
        _ body: () async throws(HueBridgeError) -> Value
    ) async -> Result<Value, HueBridgeError> {
        do {
            return try await .success(body())
        } catch {
            return .failure(error)
        }
    }

    private func connect(_ session: Session, to paired: (address: HueBridgeAddress, secrets: HueBridgeSecrets)) {
        guard let transport = dependencies.makeTransport(paired.address, paired.secrets.credentials) else {
            end(session, state: .error(.stream(.invalidCredentials)))
            return
        }
        session.transport = transport
        transport.start { [weak self] transportState in
            Task { @MainActor [weak self] in self?.transportChanged(transportState, in: session) }
        }
    }

    private func transportChanged(_ transportState: HueStreamTransportState, in session: Session) {
        guard session === self.session, !session.isEnded else { return }
        switch transportState {
        case .connecting:
            break
        case .ready:
            state = .streaming
            startTicking()
        case let .failed(error):
            let reason = LogRedaction.describe(error)
            Logger.player.error("Hue stream ended: \(reason, privacy: .public)")
            end(session, state: .error(.stream(error)))
        }
    }

    /// Main actor only: marks the session over and queues its close behind
    /// its setup, so a close never races a half-open area.
    private func end(_ session: Session, state newState: HueSyncState) {
        guard !session.isEnded else { return }
        session.isEnded = true
        session.transport?.cancel()
        if session === self.session {
            self.session = nil
            stopTicking()
            if state != newState { state = newState }
        }
        if case let .error(error) = newState { lastError = error }
        let setup = session.setup
        let defaults = dependencies.defaults
        let previous = pendingClose
        pendingClose = Task {
            await previous?.value
            await setup?.value
            if let error = await Self.close(session, defaults: defaults) {
                self.lastError = .bridge(error)
            }
        }
    }

    /// The last failure, if any.
    private static func close(_ session: Session, defaults: UserDefaults) async -> HueBridgeError? {
        guard !session.isClosed else { return nil }
        session.isClosed = true
        session.transport?.cancel()
        guard let client = session.client, let areaID = session.areaID else { return nil }
        var failure: HueBridgeError?
        if session.didStartStream {
            do {
                try await client.stopStreaming(areaID: areaID)
            } catch {
                failure = error
                let reason = LogRedaction.describe(error)
                Logger.player.error("Hue stream stop failed: \(reason, privacy: .public)")
            }
        }
        guard let snapshot = session.snapshot else { return failure }
        do {
            try await client.restore(snapshot)
            PlayerSettings.Hue.clearRestoreSnapshot(in: defaults)
        } catch {
            failure = error
            let reason = LogRedaction.describe(error)
            Logger.player.error("Hue light restore failed: \(reason, privacy: .public)")
        }
        return failure
    }

    /// A leftover snapshot holds the lamps' state from before a crashed
    /// stream; what they show now may still be that stream's colours.
    private static func merging(leftover: HueLightSnapshot?, _ captured: HueLightSnapshot) -> HueLightSnapshot {
        guard let leftover else { return captured }
        let known = Set(leftover.lights.map(\.lightID))
        let lights = leftover.lights + captured.lights.filter { !known.contains($0.lightID) }
        return HueLightSnapshot(lights: lights.sorted { $0.lightID < $1.lightID })
    }

    // MARK: - Ticks

    /// Takes the current source's frame reference and hands it to the
    /// sampler's queue. A missing frame resends the last colours, which keeps
    /// the bridge from dropping the stream while playback is paused.
    func tick() {
        guard let session, !session.isEnded, let sampler = session.sampler,
              let transport = session.transport
        else { return }
        let sample = frameSource?.latestFrame() ?? .noFrame
        switch sample {
        case let .unavailable(reason):
            if state != .unavailable(reason) { state = .unavailable(reason) }
        case .frame:
            if state != .streaming { state = .streaming }
        case .noFrame:
            break
        }
        sampler.submit(sample, at: dependencies.now()) { packet in
            transport.send(packet)
        }
    }

    private func startTicking() {
        guard tickTask == nil, let interval = dependencies.tickInterval else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}

private extension HueSyncController {
    final class Session {
        var intensity: HueIntensity
        var reduceMotion: Bool
        var setup: Task<Void, Never>?
        var isEnded = false
        var isClosed = false
        var client: HueBridgeClient?
        var areaID: String?
        var snapshot: HueLightSnapshot?
        /// A crashed session's snapshot this one merged in, kept so a refused
        /// start doesn't lose it.
        var leftoverSnapshot: HueLightSnapshot?
        var didStartStream = false
        var sampler: HueFrameSampler?
        var transport: (any HueStreamTransport)?

        init(intensity: HueIntensity, reduceMotion: Bool) {
            self.intensity = intensity
            self.reduceMotion = reduceMotion
        }
    }
}
