//
//  AetherEngineCoordinator+PictureInPicture.swift
//  Lume
//
//  Picture in Picture for AetherEngine, on whichever route serves the
//  session: `AVPlayerLayer` PiP on the native path, sample-buffer PiP on the
//  software path. The route can change mid-session, so the controller is
//  rebuilt whenever the session's PiP layer does.
//

#if !os(visionOS)

    import AVKit
    import LumeAetherBridge
    import OSLog

    @MainActor
    final class AetherPictureInPictureController: NSObject {
        private(set) var isActive = false
        /// Follows the system, not the button: PiP also starts on its own
        /// (automatic PiP on iOS) and ends from its own window.
        var onActiveChange: ((Bool) -> Void)?
        /// The PiP window went away after it was up; a failed start is not one.
        var onStop: (() -> Void)?
        var onSupportChange: ((Bool) -> Void)?

        var isSupported: Bool {
            controller != nil
        }

        private let session: LumeAetherSession
        private var controller: AVPictureInPictureController?
        private var sourceLayer: CALayer?
        private var usesSampleBuffer = false
        /// The controller whose window is up. A route change can replace
        /// `controller` while it is, and its stop still has to land.
        private var activeController: AVPictureInPictureController?

        init(session: LumeAetherSession) {
            self.session = session
            super.init()
            session.onPictureInPictureSourceChange = { [weak self] in
                self?.refresh()
            }
            refresh()
        }

        /// Rebuilds the controller when the session's PiP layer changed. Cheap
        /// when it hasn't: a fresh native host doesn't always move the route.
        func refresh() {
            let source = session.pictureInPictureSource
            let layer: CALayer? = switch source {
            case let .player(layer): layer
            case let .sampleBuffer(layer): layer
            case nil: nil
            }
            guard layer !== sourceLayer else { return }
            sourceLayer = layer
            let wasSupported = isSupported
            controller?.delegate = activeController === controller ? self : nil
            controller = source.flatMap(makeController)
            usesSampleBuffer = if case .sampleBuffer = source { controller != nil } else { false }
            if isSupported != wasSupported {
                onSupportChange?(isSupported)
            }
        }

        func toggle() {
            if isActive {
                stop()
                return
            }
            guard let controller else { return }
            guard controller.isPictureInPicturePossible else {
                Logger.player.info("AetherEngine PiP not possible yet")
                return
            }
            controller.startPictureInPicture()
        }

        func stop() {
            activeController?.stopPictureInPicture()
        }

        /// AVKit asks a sample-buffer source for its transport state only when
        /// told it changed.
        func invalidatePlaybackState() {
            guard usesSampleBuffer else { return }
            controller?.invalidatePlaybackState()
        }

        private func makeController(for source: LumeAetherPictureInPictureSource) -> AVPictureInPictureController? {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
            let contentSource: AVPictureInPictureController.ContentSource
            switch source {
            case let .player(layer):
                contentSource = .init(playerLayer: layer)
            case let .sampleBuffer(layer):
                #if os(tvOS)
                    // tvOS AVKit does not evaluate sample-buffer content
                    // sources (FB9751461).
                    _ = layer
                    return nil
                #else
                    contentSource = .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
                #endif
            }
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.delegate = self
            #if os(iOS)
                controller.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
            return controller
        }

        private func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            onActiveChange?(active)
        }

        fileprivate func willStart(_ controller: AVPictureInPictureController) {
            activeController = controller
            // At *will* start: automatic PiP begins as the app leaves the
            // foreground, and both the host's background pause and the
            // engine's background teardown must already see it.
            session.isPictureInPictureActive = true
            setActive(true)
        }

        fileprivate func didStart(_ controller: AVPictureInPictureController) {
            guard controller === activeController else { return }
            setActive(true)
            #if os(macOS)
                // Sample-buffer PiP comes out cropped on macOS without this.
                if controller === self.controller, usesSampleBuffer {
                    MacPictureInPictureScaler.shared.pictureInPictureDidStart()
                }
            #endif
        }

        fileprivate func didEnd(_ controller: AVPictureInPictureController, started: Bool) {
            guard controller === activeController else { return }
            activeController = nil
            if controller !== self.controller {
                controller.delegate = nil
            }
            session.isPictureInPictureActive = false
            #if os(macOS)
                MacPictureInPictureScaler.shared.pictureInPictureDidStop()
            #endif
            setActive(false)
            if started {
                onStop?()
            }
        }

        fileprivate func playbackTimeRange() -> CMTimeRange {
            session.pictureInPictureTimeRange()
        }

        fileprivate var isPlaybackPaused: Bool {
            session.isPictureInPicturePaused
        }

        fileprivate func setPlaying(_ playing: Bool) {
            session.setPictureInPicturePlaying(playing)
        }

        fileprivate func skip(by seconds: Double) {
            session.skipPictureInPicture(by: seconds)
        }
    }

    /// AVKit calls these on the main queue.
    extension AetherPictureInPictureController: AVPictureInPictureControllerDelegate {
        nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { willStart(controller) }
        }

        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { didStart(controller) }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { didEnd(controller, started: true) }
        }

        nonisolated func pictureInPictureController(
            _ controller: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            let reason = LogRedaction.describe(error)
            MainActor.assumeIsolated {
                Logger.player.error("AetherEngine PiP failed to start: \(reason, privacy: .public)")
                didEnd(controller, started: false)
            }
        }

        /// Without a completion the PiP window's close and return buttons
        /// wait forever on macOS. The player is still mounted underneath.
        nonisolated func pictureInPictureController(
            _: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }

    #if !os(tvOS)
        extension AetherPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
            nonisolated func pictureInPictureController(_: AVPictureInPictureController, setPlaying playing: Bool) {
                MainActor.assumeIsolated { setPlaying(playing) }
            }

            nonisolated func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
                MainActor.assumeIsolated { playbackTimeRange() }
            }

            nonisolated func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
                MainActor.assumeIsolated { isPlaybackPaused }
            }

            nonisolated func pictureInPictureController(
                _: AVPictureInPictureController,
                didTransitionToRenderSize _: CMVideoDimensions
            ) {}

            nonisolated func pictureInPictureController(
                _: AVPictureInPictureController,
                skipByInterval skipInterval: CMTime,
                completion completionHandler: @escaping () -> Void
            ) {
                let seconds = skipInterval.seconds
                MainActor.assumeIsolated { skip(by: seconds) }
                completionHandler()
            }
        }
    #endif

#endif
