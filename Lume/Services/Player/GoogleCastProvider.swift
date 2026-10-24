#if os(iOS) && canImport(GoogleCast)
    import Foundation
    import GoogleCast
    import OSLog

    /// The Google Cast SDK behind `CastProvider`, and the only code that
    /// imports it. Registered on `CastService` at launch on iOS.
    ///
    /// The SDK calls every listener method on the main thread.
    @MainActor
    final class GoogleCastProvider: NSObject, CastProvider {
        var eventHandler: ((CastProviderEvent) -> Void)?

        private(set) var devices: [CastDevice] = []
        private(set) var connectionState: CastConnectionState = .idle
        private(set) var connectedDeviceName: String?
        private(set) var status = CastPlaybackStatus.idle

        private let context: GCKCastContext

        /// The session's media client while Lume listens to it.
        private weak var mediaClient: GCKRemoteMediaClient?
        private var pendingLoad: LoadRequestObserver?
        /// Advances the position between receiver status messages.
        private var positionTicker: Task<Void, Never>?
        private var lastStatusPublish: TimeInterval?

        /// `GCKLogger` holds its delegate weakly.
        private static let logSink = GoogleCastLogSink()

        /// Must run once, before the first `GoogleCastProvider` is created.
        static func configure() {
            let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: CastReceiver.appID))
            // Discovery triggers the local-network prompt, so it waits for the
            // device sheet to ask for it.
            options.disableDiscoveryAutostart = true
            options.startDiscoveryAfterFirstTapOnCastButton = true
            options.physicalVolumeButtonsWillControlDeviceVolume = true
            // Lume can't hold the receiver socket while suspended; the SDK
            // resumes the session when the app returns to the foreground.
            options.suspendSessionsWhenBackgrounded = true
            GCKCastContext.setSharedInstanceWith(options)

            let logger = GCKLogger.sharedInstance()
            logger.consoleLoggingEnabled = false
            logger.fileLoggingEnabled = false
            let filter = GCKLoggerFilter()
            filter.minimumLevel = .warning
            logger.filter = filter
            logger.delegate = logSink
        }

        override init() {
            context = GCKCastContext.sharedInstance()
            super.init()
            context.discoveryManager.add(self)
            context.sessionManager.add(self)
            if let session = context.sessionManager.currentSession {
                connectedDeviceName = Self.displayName(of: session.device)
                connectionState = Self.connectionState(for: context.sessionManager.connectionState)
                attachMediaClient(of: session)
            }
        }

        // MARK: - Discovery

        func startDiscovery() {
            context.discoveryManager.startDiscovery()
            refreshDevices()
        }

        func stopDiscovery() {
            context.discoveryManager.stopDiscovery()
        }

        func connect(to device: CastDevice) {
            guard let gckDevice = context.discoveryManager.device(withUniqueID: device.id) else {
                Logger.player.warning("Cast connect skipped: device found=\(false, privacy: .public)")
                return
            }
            guard context.sessionManager.startSession(with: gckDevice) else {
                Logger.player.warning("Cast connect refused: started=\(false, privacy: .public)")
                return
            }
            update(connection: .connecting, deviceName: Self.displayName(of: gckDevice))
        }

        private func refreshDevices() {
            let manager = context.discoveryManager
            let updated = (0 ..< manager.deviceCount).map { Self.castDevice(from: manager.device(at: $0)) }
            guard updated != devices else { return }
            devices = updated
            eventHandler?(.devicesChanged)
        }

        // MARK: - Playback

        /// Hands `request` to the receiver and waits for its answer. A receiver
        /// that accepts the load and fails it later reports through `status`.
        func load(_ request: CastMediaRequest) async throws(CastError) {
            guard let client = remoteMediaClient else { throw .notConnected }
            pendingLoad?.finish(.superseded)
            let observer = LoadRequestObserver(client.loadMedia(with: Self.loadRequestData(for: request)))
            pendingLoad = observer
            let error = await observer.outcome()
            if pendingLoad === observer {
                pendingLoad = nil
            }
            if let error { throw error }
        }

        func play() {
            _ = remoteMediaClient?.play()
        }

        func pause() {
            _ = remoteMediaClient?.pause()
        }

        func seek(to position: TimeInterval) {
            let options = GCKMediaSeekOptions()
            options.interval = position
            _ = remoteMediaClient?.seek(with: options)
        }

        func setVolume(_ volume: Float) {
            _ = context.sessionManager.currentSession?.setDeviceVolume(volume)
        }

        func endSession(stopReceiver: Bool) {
            _ = context.sessionManager.endSessionAndStopCasting(stopReceiver)
        }

        private var remoteMediaClient: GCKRemoteMediaClient? {
            context.sessionManager.currentCastSession?.remoteMediaClient
        }

        // MARK: - State

        private func update(connection: CastConnectionState, deviceName: String?) {
            let name = connection == .idle ? nil : deviceName
            guard connection != connectionState || name != connectedDeviceName else { return }
            connectionState = connection
            connectedDeviceName = name
            eventHandler?(.connectionChanged)
        }

        private func applyVolume(_ volume: Float, muted: Bool) {
            let newVolume = muted ? 0 : volume
            guard newVolume != status.volume else { return }
            status.volume = newVolume
            eventHandler?(.statusChanged)
        }

        private func endSession(_ reason: CastSessionEnd.Reason) {
            detachMediaClient()
            pendingLoad?.finish(.notConnected)
            pendingLoad = nil
            connectionState = .idle
            connectedDeviceName = nil
            status = .idle
            eventHandler?(.sessionEnded(reason))
        }

        fileprivate static func logFailure(_ action: StaticString, _ error: Error?) {
            let detail = error.map(LogRedaction.describe) ?? "no error"
            Logger.player.warning("Cast \(action, privacy: .public) failed: \(detail, privacy: .private)")
        }

        // MARK: - Mapping

        private static func castDevice(from device: GCKDevice) -> CastDevice {
            CastDevice(
                id: device.uniqueID,
                name: displayName(of: device),
                modelName: device.modelName,
                kind: kind(of: device)
            )
        }

        private static func displayName(of device: GCKDevice) -> String {
            device.friendlyName ?? device.modelName ?? String(localized: CastDevice.unnamedName)
        }

        private static func kind(of device: GCKDevice) -> CastDevice.Kind {
            switch device.type {
            case .TV: .television
            case .speaker: .speaker
            case .speakerGroup: .speakerGroup
            default: .other
            }
        }

        private static func connectionState(for state: GCKConnectionState) -> CastConnectionState {
            switch state {
            case .connected: .connected
            case .connecting: .connecting
            default: .idle
            }
        }
    }

    // MARK: - GCKDiscoveryManagerListener

    extension GoogleCastProvider: GCKDiscoveryManagerListener {
        func didUpdateDeviceList() {
            refreshDevices()
        }
    }

    // MARK: - GCKSessionManagerListener

    extension GoogleCastProvider: GCKSessionManagerListener {
        func sessionManager(_: GCKSessionManager, willStart session: GCKSession) {
            update(connection: .connecting, deviceName: Self.displayName(of: session.device))
        }

        func sessionManager(_: GCKSessionManager, didStart session: GCKSession) {
            update(connection: .connected, deviceName: Self.displayName(of: session.device))
            applyVolume(session.currentDeviceVolume, muted: session.currentDeviceMuted)
            attachMediaClient(of: session)
        }

        func sessionManager(_: GCKSessionManager, willResumeSession session: GCKSession) {
            update(connection: .connecting, deviceName: Self.displayName(of: session.device))
        }

        /// Also the launch path: the SDK resumes the previous session and the
        /// receiver's media status stands in for the item Lume no longer has.
        func sessionManager(_: GCKSessionManager, didResumeSession session: GCKSession) {
            update(connection: .connected, deviceName: Self.displayName(of: session.device))
            applyVolume(session.currentDeviceVolume, muted: session.currentDeviceMuted)
            attachMediaClient(of: session)
            _ = session.remoteMediaClient?.requestStatus()
        }

        func sessionManager(_: GCKSessionManager, didFailToStart _: GCKSession, withError error: Error) {
            Self.logFailure("session start", error)
            update(connection: .idle, deviceName: nil)
        }

        func sessionManager(
            _: GCKSessionManager,
            didSuspend session: GCKSession,
            with reason: GCKConnectionSuspendReason
        ) {
            // Backgrounding suspends every session and the SDK resumes it on
            // return, so the session stays connected for Lume's purposes;
            // anything else is a dropped connection the SDK is retrying.
            guard reason != .appBackgrounded else { return }
            update(connection: .connecting, deviceName: Self.displayName(of: session.device))
        }

        func sessionManager(_: GCKSessionManager, didEnd _: GCKSession, withError error: Error?) {
            if error != nil {
                Self.logFailure("session", error)
            }
            endSession(error == nil ? .stopped : .disconnected)
        }

        func sessionManager(
            _: GCKSessionManager,
            session _: GCKSession,
            didReceiveDeviceVolume volume: Float,
            muted: Bool
        ) {
            applyVolume(volume, muted: muted)
        }

        func sessionManager(_: GCKSessionManager, session _: GCKSession, didUpdate device: GCKDevice) {
            guard connectionState != .idle else { return }
            update(connection: connectionState, deviceName: Self.displayName(of: device))
        }
    }

    // MARK: - Media status

    extension GoogleCastProvider: GCKRemoteMediaClientListener {
        func remoteMediaClient(_: GCKRemoteMediaClient, didUpdate _: GCKMediaStatus?) {
            refreshStatus()
        }

        private func attachMediaClient(of session: GCKSession) {
            guard let client = session.remoteMediaClient, client !== mediaClient else { return }
            mediaClient?.remove(self)
            client.add(self)
            mediaClient = client
            refreshStatus()
        }

        private func detachMediaClient() {
            mediaClient?.remove(self)
            mediaClient = nil
            positionTicker?.cancel()
            positionTicker = nil
            lastStatusPublish = nil
        }

        private func refreshStatus() {
            let receiver = mediaClient.flatMap { client in
                client.mediaStatus.map { Self.receiverStatus($0, position: client.approximateStreamPosition()) }
            }
            let newStatus = CastStatusMapping.status(from: receiver, volume: status.volume)
            let now = ProcessInfo.processInfo.systemUptime
            guard CastStatusMapping.shouldPublish(newStatus, over: status, lastPublishedAt: lastStatusPublish, now: now)
            else { return }

            if newStatus.idleReason == .error, status.idleReason != .error {
                Logger.player.warning("Cast receiver failed the media")
            }
            status = newStatus
            lastStatusPublish = now
            eventHandler?(.statusChanged)
            updatePositionTicker()
        }

        private func updatePositionTicker() {
            guard status.isPlaying else {
                positionTicker?.cancel()
                positionTicker = nil
                return
            }
            guard positionTicker == nil else { return }
            positionTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(CastStatusMapping.positionUpdateInterval))
                    guard !Task.isCancelled else { return }
                    self?.refreshStatus()
                }
            }
        }

        private static func receiverStatus(
            _ mediaStatus: GCKMediaStatus,
            position: TimeInterval
        ) -> CastStatusMapping.ReceiverStatus {
            let info = mediaStatus.mediaInformation
            let metadata = info?.metadata
            return CastStatusMapping.ReceiverStatus(
                playerState: playerState(mediaStatus.playerState),
                idleReason: idleReason(mediaStatus.idleReason),
                position: position,
                streamDuration: info?.streamDuration ?? 0,
                isLive: info?.streamType == .live,
                title: metadata?.string(forKey: kGCKMetadataKeyTitle),
                subtitle: metadata?.string(forKey: kGCKMetadataKeySubtitle)
                    ?? metadata?.string(forKey: kGCKMetadataKeySeriesTitle),
                posterURL: metadata?.images().lazy.compactMap { ($0 as? GCKImage)?.url }.first
            )
        }

        private static func playerState(_ state: GCKMediaPlayerState) -> CastStatusMapping.PlayerState {
            switch state {
            case .unknown: .unknown
            case .idle: .idle
            case .playing: .playing
            case .paused: .paused
            case .buffering: .buffering
            case .loading: .loading
            }
        }

        private static func idleReason(_ reason: GCKMediaPlayerIdleReason) -> CastStatusMapping.ReceiverIdleReason {
            switch reason {
            case .finished: .finished
            case .cancelled: .cancelled
            case .interrupted: .interrupted
            case .error: .error
            default: .none
            }
        }
    }

    // MARK: - Load request

    extension GoogleCastProvider {
        fileprivate static func loadRequestData(for request: CastMediaRequest) -> GCKMediaLoadRequestData {
            let metadata = GCKMediaMetadata(metadataType: metadataType(for: request.contentRef))
            metadata.setString(request.title, forKey: kGCKMetadataKeyTitle)
            if let subtitle = request.subtitle {
                metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
            }
            if let posterURL = request.posterURL {
                metadata.addImage(GCKImage(url: posterURL, width: 0, height: 0))
            }
            let media = GCKMediaInformationBuilder(contentURL: request.contentURL)
            media.contentType = request.contentType
            media.streamType = request.streamType == .live ? .live : .buffered
            media.metadata = metadata
            if request.hasMPEGTSSegments {
                media.hlsSegmentFormat = .TS
                media.hlsVideoSegmentFormat = .MPEG2_TS
            }
            let load = GCKMediaLoadRequestDataBuilder()
            load.mediaInformation = media.build()
            if let startTime = CastStatusMapping.loadStartTime(for: request) {
                load.startTime = startTime
            }
            load.autoplay = true
            return load.build()
        }

        private static func metadataType(for contentRef: PlayableMedia.ContentRef) -> GCKMediaMetadataType {
            switch CastStatusMapping.metadataKind(for: contentRef) {
            case .movie: .movie
            case .tvShow: .tvShow
            case .generic: .generic
            }
        }
    }

    /// Waits for the receiver's answer to one load. `GCKRequest` holds its
    /// delegate weakly, so the provider keeps the observer until it finishes.
    private final class LoadRequestObserver: NSObject, GCKRequestDelegate {
        private let request: GCKRequest
        private var continuation: CheckedContinuation<CastError?, Never>?
        private var result: CastError??

        init(_ request: GCKRequest) {
            self.request = request
            super.init()
            request.delegate = self
            if !request.inProgress {
                finish(request.error == nil ? nil : .loadFailed)
            }
        }

        /// `nil` once the receiver accepted the load.
        func outcome() async -> CastError? {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ error: CastError?) {
            guard result == nil else { return }
            result = .some(error)
            request.delegate = nil
            continuation?.resume(returning: error)
            continuation = nil
        }

        func requestDidComplete(_: GCKRequest) {
            finish(nil)
        }

        func request(_: GCKRequest, didFailWithError error: GCKError) {
            GoogleCastProvider.logFailure("media load", error)
            finish(.loadFailed)
        }

        func request(_: GCKRequest, didAbortWith _: GCKRequestAbortReason) {
            finish(.superseded)
        }
    }

    /// Routes the SDK's own warnings into `Logger.player`. Its messages can
    /// name receivers and echo stream URLs, so they stay private and pass
    /// through `LogRedaction` first.
    private final nonisolated class GoogleCastLogSink: NSObject, GCKLoggerDelegate {
        func logMessage(_ message: String, at level: GCKLoggerLevel, fromFunction function: String, location _: String) {
            let scrubbed = LogRedaction.scrubURLs(in: message)
            if level.rawValue >= GCKLoggerLevel.error.rawValue {
                Logger.player.error("GoogleCast \(function, privacy: .public): \(scrubbed, privacy: .private)")
            } else {
                Logger.player.warning("GoogleCast \(function, privacy: .public): \(scrubbed, privacy: .private)")
            }
        }
    }
#endif
