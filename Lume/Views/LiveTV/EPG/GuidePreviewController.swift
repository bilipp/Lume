//
//  GuidePreviewController.swift
//  Lume
//
//  What holds the tvOS Guide preview off and when it restarts. A reference
//  that only the preview band reads, so opening full screen, a scene-phase
//  change or a restart re-renders the band rather than Live TV and the grid.
//

import SwiftUI

@MainActor @Observable
final class GuidePreviewController {
    /// Lets full screen adopt the Guide preview's running stream.
    let handle = PreviewPlayerHandle()
    /// Bumped to reopen the Guide preview on a fresh stream.
    private(set) var restartToken = 0
    /// Holds the preview off briefly after full screen or Multi-View closes,
    /// so the provider has freed that connection first.
    private(set) var isCoolingDown = false

    private var isFullScreenUp = false
    private var isMultiViewUp = false
    private var isSceneActive = true

    /// Full screen or Multi-View is up, the app left the foreground, or the
    /// connection they used is still being freed.
    var isSuspended: Bool {
        isBlocked || isCoolingDown
    }

    private var isBlocked: Bool {
        isFullScreenUp || isMultiViewUp || !isSceneActive
    }

    /// Select on the channel the Guide is previewing takes its running stream
    /// over where the engine allows it. Otherwise the preview stops before
    /// full screen opens, and the full player's own retry and fallback absorb
    /// the provider still freeing that connection.
    func prepareToPresent(_ media: PlayableMedia) {
        if handle.canAdopt(media, airPlayActive: CastService.shared.isAirPlayActive) {
            handle.handOffToFullScreen()
        } else {
            handle.stopPreview()
        }
        transition { isFullScreenUp = true }
    }

    /// Reopens on a fresh stream once the connection is free, so the band
    /// never sits on a reset tile.
    func stopForExternalPlayback() {
        handle.stopPreview()
        coolDown()
    }

    func fullScreenDidClose() {
        transition { isFullScreenUp = false }
        handle.release()
    }

    func setMultiViewUp(_ isUp: Bool) {
        transition { isMultiViewUp = isUp }
    }

    func setSceneActive(_ isActive: Bool) {
        transition { isSceneActive = isActive }
    }

    func coolDown() {
        isCoolingDown = true
    }

    func finishCoolingDown() {
        isCoolingDown = false
        restartToken += 1
    }

    private func transition(_ apply: () -> Void) {
        let wasBlocked = isBlocked
        apply()
        if wasBlocked, !isBlocked { isCoolingDown = true }
    }
}

#if os(tvOS)
    extension View {
        /// Feeds the controller the presentation state that suspends the
        /// preview, from a modifier so those reads never re-render the view
        /// it is attached to.
        func guidePreviewSuspension(
            _ controller: GuidePreviewController,
            playingMedia: Binding<PlayableMedia?>
        ) -> some View {
            modifier(GuidePreviewSuspension(controller: controller, playingMedia: playingMedia))
        }
    }

    private struct GuidePreviewSuspension: ViewModifier {
        let controller: GuidePreviewController
        @Binding var playingMedia: PlayableMedia?

        @Environment(DeepLinkRouter.self) private var router
        @Environment(\.scenePhase) private var scenePhase

        func body(content: Content) -> some View {
            content
                .onChange(of: playingMedia == nil) { _, isDismissed in
                    guard isDismissed else { return }
                    controller.fullScreenDidClose()
                }
                .onChange(of: router.multiViewLaunch != nil, initial: true) { _, isUp in
                    controller.setMultiViewUp(isUp)
                }
                .onChange(of: scenePhase == .active, initial: true) { _, isActive in
                    controller.setSceneActive(isActive)
                }
                .task(id: controller.isCoolingDown) {
                    guard controller.isCoolingDown else { return }
                    try? await Task.sleep(for: GuidePreviewPolicy.restartDelay)
                    guard !Task.isCancelled else { return }
                    controller.finishCoolingDown()
                }
        }
    }
#endif
