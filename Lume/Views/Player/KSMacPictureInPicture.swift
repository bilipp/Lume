//
//  KSMacPictureInPicture.swift
//  Lume
//
//  Drives KSPlayer's Picture in Picture on macOS.
//
//  KSPlayer's own path — `KSPlayerLayer.isPipActive` — makes the layer the PiP
//  controller's delegate, and that delegate never completes AVKit's restore
//  handshake: `restoreUserInterfaceForPictureInPictureStop` drops its completion
//  handler, then clears itself as the delegate while the stop is still in
//  flight. On macOS that leaves both buttons in the PiP window dead — the close
//  button and "return to the app" each wait on a restore that never finishes.
//  So on macOS Lume starts and stops the controller itself and owns the
//  delegate, and never touches the layer's flag.
//

#if os(macOS)
    import AppKit
    import AVKit
    import KSPlayer
    import OSLog

    @Observable
    final class KSMacPictureInPicture: NSObject {
        private(set) var isActive = false

        @ObservationIgnored private weak var layer: KSPlayerLayer?
        @ObservationIgnored private weak var controller: AVPictureInPictureController?
        /// Set once the stop in flight is one the viewer or the app asked for
        /// (the PiP window's return button, or the player's own PiP toggle), so
        /// the stop is not taken for the close button.
        @ObservationIgnored private var isStopRequested = false
        @ObservationIgnored private var restoresWindowOnStop = true
        /// The controller `prepare` last saw, and when, so `start` can tell a
        /// controller that has settled from one KSPlayer only just created.
        @ObservationIgnored private weak var preparedController: AVPictureInPictureController?
        @ObservationIgnored private var preparedAt: Date?
        @ObservationIgnored private var startTask: Task<Void, Never>?
        private static let settleTime: TimeInterval = 0.5

        func toggle(_ layer: KSPlayerLayer?) {
            if isActive {
                stop()
            } else {
                start(layer)
            }
        }

        /// Create the PiP controller ahead of the first PiP request. KSPlayer
        /// builds it lazily on first access, and AVKit starting PiP on a controller
        /// created in the same turn crashes the app ("Invalid view geometry: x
        /// is NaN" out of its PiP host view's layout) — the render size has not
        /// reached it yet. Called once playback is up.
        func prepare(_ layer: KSPlayerLayer?) {
            guard let controller = layer?.player.pipController, controller !== preparedController else { return }
            preparedController = controller
            preparedAt = .now
        }

        func start(_ layer: KSPlayerLayer?) {
            // Fetched fresh every time: KSPlayer replaces the controller whenever
            // the stream's format changes and it swaps in a new display layer.
            guard let layer, let controller = layer.player.pipController else {
                Logger.player.info("KSPlayer PiP unavailable: the player has no PiP controller")
                return
            }
            self.layer = layer
            self.controller = controller
            isStopRequested = false
            controller.delegate = self
            // A controller that has not had a moment to settle — never prepared,
            // or replaced since — starts after a short grace period instead.
            let settled = controller === preparedController && preparedAt.map { Date.now.timeIntervalSince($0) > Self.settleTime } == true
            prepare(layer)
            guard !settled else {
                controller.startPictureInPicture()
                return
            }
            startTask?.cancel()
            startTask = Task { @MainActor [weak controller] in
                try? await Task.sleep(for: .seconds(Self.settleTime))
                guard !Task.isCancelled, let controller, !controller.isPictureInPictureActive else { return }
                controller.startPictureInPicture()
            }
        }

        /// - Parameter restoringWindow: `false` when the player itself is going
        ///   away, so the stop does not raise a window that is closing.
        func stop(restoringWindow: Bool = true) {
            startTask?.cancel()
            guard let controller, controller.isPictureInPictureActive else {
                isActive = false
                return
            }
            isStopRequested = true
            restoresWindowOnStop = restoringWindow
            controller.stopPictureInPicture()
        }

        /// Bring the player window back to the front, out of the Dock if the
        /// viewer minimized it while PiP was up.
        private func restorePlayerWindow() {
            guard let window = layer?.player.view?.window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    extension KSMacPictureInPicture: AVPictureInPictureControllerDelegate {
        func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
            isActive = true
            MacPictureInPictureScaler.shared.pictureInPictureDidStart()
        }

        func pictureInPictureController(
            _: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            isStopRequested = true
            if restoresWindowOnStop { restorePlayerWindow() }
            // The call KSPlayer's delegate never makes. Until it is made AVKit
            // holds the PiP window open.
            completionHandler(true)
        }

        func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
            // Closed with the PiP window's close button: stop playing, as a Mac
            // player does, rather than carry on unseen in the window behind.
            if !isStopRequested { layer?.pause() }
            MacPictureInPictureScaler.shared.pictureInPictureDidStop()
            isActive = false
            isStopRequested = false
            restoresWindowOnStop = true
        }

        func pictureInPictureController(
            _: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            isActive = false
            Logger.player.error("KSPlayer PiP failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }
#endif
