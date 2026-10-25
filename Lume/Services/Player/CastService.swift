import AVFoundation
import Foundation
import OSLog

/// Coordinates "casting" — sending playback to an external device — for the
/// player overlay, independent of which playback engine is active.
///
/// AirPlay is routed natively by AVFoundation, so this service just observes
/// the audio route and surfaces whether playback is currently leaving the
/// device. Google Cast (Chromecast) plugs in through the `CastProvider` seam:
/// the service mirrors the provider's devices, connection and receiver status
/// as observable state, remembers what was loaded so watch progress can be
/// committed after the player that started the cast has closed, and tells
/// session-end observers when the receiver stops playing it.
///
/// Per-engine AirPlay reality: only the AVPlayer engine can hand full-screen
/// video to an AirPlay receiver (it enables `allowsExternalPlayback`). KSPlayer
/// and VLCKit render into their own layers, so AirPlay would carry only their
/// audio — so when `isAirPlayActive` flips, `FullScreenPlayerView` drives the
/// stream through the AVPlayer engine for the duration of the cast. The route
/// state tracked here is engine-agnostic because AirPlay always reshapes the
/// shared audio route.
///
/// macOS has no `AVAudioSession`, so route observation — and with it the
/// engine handoff — doesn't exist there: `isAirPlayActive` stays `false` and
/// AirPlay is available only on the AVPlayer engine, whose overlay binds the
/// route picker to its player directly (see `AirPlayRouteButton`). tvOS is
/// likewise excluded: the Apple TV is itself the AirPlay destination, so its
/// route always looks "external" and the handoff would wrongly pin every
/// stream to AVPlayer, ignoring the user's engine priority.
@MainActor
@Observable
final class CastService {
    static let shared = CastService()

    /// Whether playback is currently routed to an external AirPlay receiver.
    var isAirPlayActive: Bool {
        airPlayRouteName != nil
    }

    /// Display name of the active AirPlay route, when the system reports one.
    private(set) var airPlayRouteName: String?

    /// The Google Cast backend, registered at launch on iOS. `nil` everywhere
    /// else, which leaves every Chromecast property at its idle value.
    var castProvider: (any CastProvider)? {
        didSet {
            oldValue?.eventHandler = nil
            attachProvider()
        }
    }

    /// Cast receivers found by discovery.
    private(set) var devices: [CastDevice] = []

    private(set) var chromecastConnection: CastConnectionState = .idle

    /// Name of the receiver Lume is connected (or connecting) to.
    private(set) var chromecastDeviceName: String?

    /// The receiver's media status, refreshed by the provider about once a
    /// second while media plays and on every state change. Not observed, so
    /// the per-second position moves no view; views read the two properties
    /// below, and everything else follows `observeStatus`.
    @ObservationIgnored private(set) var status = CastPlaybackStatus.idle {
        didSet {
            if status.isActive != isReceiverPlaying {
                isReceiverPlaying = status.isActive
            }
            if status.volume != receiverVolume {
                receiverVolume = status.volume
            }
        }
    }

    /// Whether the receiver is playing or buffering on its way to playing.
    private(set) var isReceiverPlaying = false

    /// The receiver's volume, 0...1.
    private(set) var receiverVolume = CastPlaybackStatus.idle.volume

    /// What Lume last loaded on the receiver, kept past the player's close so
    /// the mini-controller and the progress commit still know what's playing.
    /// `nil` for a session the SDK resumed at launch — `status` then carries
    /// the receiver's own metadata.
    private(set) var currentRequest: CastMediaRequest?

    /// The stream behind `currentRequest`, when the player that loaded it
    /// handed it over, so the mini-controller can reopen the player on it.
    private(set) var castingMedia: PlayableMedia?

    /// Set when the viewer picks a receiver for the open player, and consumed
    /// by the player once it starts the cast. A session the SDK resumed on its
    /// own never sets it, so it can't hijack a player that is playing locally.
    private(set) var isPlayerCastRequested = false

    /// Writes progress for casts that end with no player open. Set at launch.
    @ObservationIgnored var progressCommitter: CastProgressCommitter?

    var isChromecastActive: Bool {
        chromecastConnection == .connected
    }

    /// The catalog item the receiver is playing, when Lume loaded it.
    var currentContentRef: PlayableMedia.ContentRef? {
        currentRequest?.contentRef
    }

    /// Where playback leaves the device, with Google Cast taking precedence.
    var route: CastRoute {
        Self.route(
            airPlayName: airPlayRouteName,
            chromecast: chromecastConnection,
            chromecastDeviceName: chromecastDeviceName
        )
    }

    /// Players committing their own cast progress; else `progressCommitter` does.
    private var progressHosts: Set<String> = []

    /// Whether the receiver has played media since the last end, so an idle
    /// status after it means that media ended — also for a resumed session.
    @ObservationIgnored private var hasActiveMedia = false
    @ObservationIgnored private var lastPosition: TimeInterval = 0
    @ObservationIgnored private var lastDuration: TimeInterval?
    @ObservationIgnored private var sessionEndHandlers: [String: (CastSessionEnd) -> Void] = [:]
    @ObservationIgnored private var statusHandlers: [String: (CastPlaybackStatus) -> Void] = [:]
    @ObservationIgnored private var sessionStartInterval: PerfInterval?

    /// Touched from the nonisolated `deinit`; `removeObserver` is thread-safe.
    private nonisolated(unsafe) var routeObserver: (any NSObjectProtocol)?

    init(castProvider: (any CastProvider)? = nil) {
        self.castProvider = castProvider
        refreshAirPlayRoute()
        observeRouteChanges()
        attachProvider()
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    // MARK: - Route

    /// A single output of the current audio route, reduced to the fields the
    /// AirPlay check needs so the matching logic stays unit-testable without a
    /// live `AVAudioSession`.
    struct RouteOutput: Equatable {
        let isAirPlay: Bool
        let name: String
    }

    /// The name of the first AirPlay output among the given route outputs, or
    /// `nil` when none is AirPlay. Pure, so it can be exercised in tests.
    static func activeAirPlayName(in outputs: [RouteOutput]) -> String? {
        outputs.first(where: \.isAirPlay)?.name
    }

    /// AirPlay and Chromecast folded into one route. They are mutually
    /// exclusive in the player, and a Chromecast session — even one still
    /// connecting — wins over an AirPlay route the system still reports.
    nonisolated static func route(
        airPlayName: String?,
        chromecast: CastConnectionState,
        chromecastDeviceName: String?
    ) -> CastRoute {
        switch chromecast {
        case .connected: .chromecast(deviceName: chromecastDeviceName)
        case .connecting: .connectingChromecast(deviceName: chromecastDeviceName)
        case .idle: airPlayName.map(CastRoute.airPlay) ?? .local
        }
    }

    // MARK: - Chromecast control

    func startDiscovery() {
        castProvider?.startDiscovery()
    }

    func stopDiscovery() {
        castProvider?.stopDiscovery()
    }

    func connect(to device: CastDevice) {
        guard let castProvider else { return }
        isPlayerCastRequested = true
        if sessionStartInterval == nil {
            sessionStartInterval = Perf.begin(.castSessionStart)
        }
        castProvider.connect(to: device)
    }

    /// Asks the open player to cast to the receiver that is already
    /// connected, where picking it again starts no new connection.
    func requestPlayerCast() {
        isPlayerCastRequested = true
    }

    func consumePlayerCastRequest() {
        isPlayerCastRequested = false
    }

    /// Loads `request` on the connected receiver. It becomes `currentRequest`
    /// — with `media`, the stream it was built from — only once the receiver
    /// accepts it, so a failed load leaves the previous item (if any) in place
    /// for the caller's fallback.
    func load(_ request: CastMediaRequest, media: PlayableMedia? = nil) async throws(CastError) {
        guard let castProvider, castProvider.connectionState == .connected else { throw .notConnected }
        let interval = Perf.begin(.castMediaLoad)
        defer { Perf.end(interval) }
        try await castProvider.load(request)
        currentRequest = request
        castingMedia = media
        hasActiveMedia = false
        lastPosition = request.startTime
        lastDuration = nil
    }

    func play() {
        castProvider?.play()
    }

    func pause() {
        castProvider?.pause()
    }

    func seek(to position: TimeInterval) {
        castProvider?.seek(to: max(0, position))
    }

    func setVolume(_ volume: Float) {
        castProvider?.setVolume(min(max(volume, 0), 1))
    }

    /// Ends the Cast session. `stopReceiver` also stops the receiver app;
    /// without it the receiver keeps playing on its own.
    func endSession(stopReceiver: Bool) {
        castProvider?.endSession(stopReceiver: stopReceiver)
    }

    // MARK: - Session-end observers

    /// Calls `handler` each time the receiver stops playing media Lume tracked
    /// — it finished, was stopped, failed, or the session went away. One
    /// handler per `owner`; registering again replaces it.
    func observeSessionEnd(owner: String, _ handler: @escaping (CastSessionEnd) -> Void) {
        sessionEndHandlers[owner] = handler
    }

    func removeSessionEndObserver(owner: String) {
        sessionEndHandlers[owner] = nil
    }

    /// Calls `handler` with every receiver status the provider reports —
    /// about once a second while media plays. One handler per `owner`.
    func observeStatus(owner: String, _ handler: @escaping (CastPlaybackStatus) -> Void) {
        statusHandlers[owner] = handler
    }

    func removeStatusObserver(owner: String) {
        statusHandlers[owner] = nil
    }

    /// `owner` commits the progress of what the receiver plays from `ref` on.
    /// Media a closed player left playing that `ref` replaces is committed first.
    func attachProgressHost(owner: String, playing ref: PlayableMedia.ContentRef) {
        if progressHosts.isEmpty, let previous = currentRequest, previous.contentRef != ref {
            commitHeadless(CastSessionEnd(
                reason: .stopped, lastPosition: lastPosition, duration: lastDuration, request: previous
            ))
        }
        progressHosts.insert(owner)
    }

    /// Whether an open player is showing this cast.
    var isHostedByPlayer: Bool {
        !progressHosts.isEmpty
    }

    /// `settled`: the player committed the media's end itself, so the
    /// receiver's own end report that follows must not commit it again.
    func detachProgressHost(owner: String, settled: Bool = false) {
        progressHosts.remove(owner)
        if settled, progressHosts.isEmpty {
            forgetMedia()
        }
    }

    private func commitHeadless(_ end: CastSessionEnd) {
        let hostAttached = !progressHosts.isEmpty
        if let commit = PlayerCastPolicy.headlessCommit(for: end, hostAttached: hostAttached) {
            progressCommitter?.commit(commit)
        }
    }

    // MARK: - Provider events

    private func attachProvider() {
        castProvider?.eventHandler = { [weak self] event in self?.handle(event) }
        devices = castProvider?.devices ?? []
        syncConnection()
        status = castProvider?.status ?? .idle
    }

    private func handle(_ event: CastProviderEvent) {
        switch event {
        case .devicesChanged:
            devices = castProvider?.devices ?? []
        case .connectionChanged:
            syncConnection()
        case .statusChanged:
            apply(castProvider?.status ?? .idle)
        case let .sessionEnded(reason):
            finishMedia(reason)
            status = .idle
            syncConnection()
        }
    }

    private func syncConnection() {
        let connection = castProvider?.connectionState ?? .idle
        chromecastDeviceName = connection == .idle ? nil : castProvider?.connectedDeviceName
        if connection == .idle {
            isPlayerCastRequested = false
        }
        if connection != .connecting, let interval = sessionStartInterval {
            Perf.end(interval)
            sessionStartInterval = nil
        }
        if connection != chromecastConnection {
            chromecastConnection = connection
            let connected = connection == .connected
            Logger.player.log("Cast connection changed: connected=\(connected, privacy: .public)")
        }
    }

    private func apply(_ newStatus: CastPlaybackStatus) {
        let previousIdleReason = status.idleReason
        status = newStatus
        for handler in statusHandlers.values {
            handler(newStatus)
        }
        if newStatus.hasMedia, newStatus.idleReason == nil {
            hasActiveMedia = true
            lastPosition = newStatus.position
            lastDuration = newStatus.duration ?? lastDuration
        } else if let idleReason = newStatus.idleReason, idleReason != previousIdleReason,
                  let reason = idleReason.sessionEndReason
        {
            finishMedia(reason)
        }
    }

    /// Reports the end of the tracked media once, then forgets it. Media Lume
    /// loaded counts even before it played, so a receiver that accepts a load
    /// and then fails it still reaches the caller's fallback.
    private func finishMedia(_ reason: CastSessionEnd.Reason) {
        guard hasActiveMedia || currentRequest != nil else { return }
        let end = CastSessionEnd(
            reason: reason,
            lastPosition: lastPosition,
            duration: lastDuration,
            request: currentRequest
        )
        commitHeadless(end)
        forgetMedia()
        let isError = reason == .error
        Logger.player.log("Cast media ended: error=\(isError, privacy: .public)")
        for handler in sessionEndHandlers.values {
            handler(end)
        }
    }

    private func forgetMedia() {
        hasActiveMedia = false
        currentRequest = nil
        castingMedia = nil
    }

    // MARK: - AirPlay observation

    private func refreshAirPlayRoute() {
        // tvOS is the AirPlay *destination*, not a device casting elsewhere: its
        // audio route reports an external/AirPlay-style output almost always,
        // which would spuriously force the AVPlayer engine (see the override in
        // FullScreenPlayerView) and ignore the user's engine priority. So route
        // observation — and the engine handoff — is iOS/visionOS only.
        #if os(iOS) || os(visionOS)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
                RouteOutput(isAirPlay: $0.portType == .airPlay, name: $0.portName)
            }
            let name = Self.activeAirPlayName(in: outputs)
            if name != airPlayRouteName {
                airPlayRouteName = name
                Logger.player.log("AirPlay route changed: active=\(name != nil, privacy: .public)")
            }
        #endif
    }

    private func observeRouteChanges() {
        #if os(iOS) || os(visionOS)
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAirPlayRoute() }
            }
        #endif
    }
}
