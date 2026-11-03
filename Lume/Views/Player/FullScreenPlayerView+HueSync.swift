//
//  FullScreenPlayerView+HueSync.swift
//  Lume
//
//  The full-screen player's half of Philips Hue light sync. The host opens
//  the session when the player appears and ends it, restoring the lamps, when
//  the player goes, the app backgrounds or a cast starts. Each engine view
//  registers its coordinator's frame source while it is on screen, so a zap
//  keeps the stream and a fallback or Guide adoption only swaps the source.
//
//  tvOS only. Elsewhere the hooks return the view unchanged.
//

import KSPlayer
import SwiftUI

/// An engine coordinator that can hand Hue its frames.
protocol HueFrameSourceProviding: AnyObject {
    #if os(tvOS)
        func makeHueFrameSource() -> any HueFrameSource
    #endif
}

extension LumeEngineCoordinator: HueFrameSourceProviding {
    #if os(tvOS)
        func makeHueFrameSource() -> any HueFrameSource {
            LumeEngineHueFrameSource(coordinator: self)
        }
    #endif
}

#if !os(visionOS)
    extension AetherEngineCoordinator: HueFrameSourceProviding {
        #if os(tvOS)
            func makeHueFrameSource() -> any HueFrameSource {
                AetherEngineHueFrameSource(coordinator: self)
            }
        #endif
    }
#endif

extension KSVideoPlayer.Coordinator: HueFrameSourceProviding {
    #if os(tvOS)
        func makeHueFrameSource() -> any HueFrameSource {
            KSPlayerHueFrameSource(coordinator: self)
        }
    #endif
}

extension AVPlayerCoordinator: HueFrameSourceProviding {
    #if os(tvOS)
        func makeHueFrameSource() -> any HueFrameSource {
            UnsupportedHueFrameSource()
        }
    #endif
}

extension VLCPlayerCoordinator: HueFrameSourceProviding {
    #if os(tvOS)
        func makeHueFrameSource() -> any HueFrameSource {
            UnsupportedHueFrameSource()
        }
    #endif
}

extension View {
    /// Runs Hue sync for the full-screen player around this view.
    func playerHueSync(isCasting: Bool) -> some View {
        #if os(tvOS)
            modifier(PlayerHueSync(isCasting: isCasting))
        #else
            self
        #endif
    }

    /// Registers `engine`'s frame source with the enclosing Hue session, if
    /// any, while this view is on screen.
    func hueFrameSource(_ engine: some HueFrameSourceProviding, isPictureInPicture: Bool = false) -> some View {
        #if os(tvOS)
            modifier(HueFrameSourceRegistration(engine: engine, isPictureInPicture: isPictureInPicture))
        #else
            self
        #endif
    }
}

#if os(tvOS)
    extension EnvironmentValues {
        /// Set only by the full-screen player, for its Hue menu.
        @Entry var hueSync: HueSyncController?
        /// Where an engine view registers its frame source: the full-screen
        /// player, or a Multi-View slot. Guide previews never get one.
        @Entry var hueFrameSourceSink: HueFrameSourceSink?
    }

    enum HueFrameSourceSink {
        case player(HueSyncController)
        case multiViewSlot(HueSourceRouter<MultiViewSlot.ID>, MultiViewSlot.ID)

        func register(_ source: any HueFrameSource) {
            switch self {
            case let .player(controller): controller.setSource(source)
            case let .multiViewSlot(router, slotID): router.register(source, for: slotID)
            }
        }

        func unregister(_ source: any HueFrameSource) {
            switch self {
            case let .player(controller): controller.clearSource(source)
            case let .multiViewSlot(router, slotID): router.unregister(source, for: slotID)
            }
        }
    }

    /// Engines without a frame tap report themselves, so the player menu can
    /// say sync is unavailable while the lamps hold their colours.
    final class UnsupportedHueFrameSource: HueFrameSource {
        var unavailableReason: HueFrameUnavailableReason? {
            .unsupportedEngine
        }

        func latestFrame() -> HueFrameSample {
            .unavailable(.unsupportedEngine)
        }

        func detach() {}
    }

    private struct PlayerHueSync: ViewModifier {
        let isCasting: Bool

        private var controller: HueSyncController {
            HueSyncController.shared
        }

        func body(content: Content) -> some View {
            content
                .environment(\.hueSync, controller)
                .environment(\.hueFrameSourceSink, .player(controller))
                .modifier(HueSessionLifecycle(isSuspendedExternally: isCasting))
        }
    }

    /// Opens the shared session on appear and again on returning to the
    /// foreground (`LumeApp` suspends it in the background), and ends it,
    /// restoring the lamps, on disappear. `isSuspendedExternally` (a cast)
    /// ends it too, and lifting it opens it again; `onEnd` runs before the
    /// session stops.
    struct HueSessionLifecycle: ViewModifier {
        var isSuspendedExternally = false
        var onEnd: () -> Void = {}

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase

        private var controller: HueSyncController {
            HueSyncController.shared
        }

        func body(content: Content) -> some View {
            content
                .onAppear {
                    guard !isSuspendedExternally else { return }
                    controller.startIfEligible(reduceMotion: reduceMotion)
                }
                .onChange(of: reduceMotion) { _, reduce in controller.setReduceMotion(reduce) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, !isSuspendedExternally else { return }
                    controller.startIfEligible(reduceMotion: reduceMotion)
                }
                .onChange(of: isSuspendedExternally) { _, suspended in
                    if suspended {
                        controller.stop()
                    } else {
                        controller.startIfEligible(reduceMotion: reduceMotion)
                    }
                }
                .onDisappear {
                    onEnd()
                    controller.stop()
                }
        }
    }

    /// Keeps the engine's source alive while its view is on screen; the
    /// session only holds it weakly. Picture in Picture ends the player's
    /// session.
    private struct HueFrameSourceRegistration: ViewModifier {
        let engine: any HueFrameSourceProviding
        let isPictureInPicture: Bool

        @Environment(\.hueFrameSourceSink) private var sink
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var source: (any HueFrameSource)?

        func body(content: Content) -> some View {
            content
                .onAppear(perform: register)
                .onChange(of: isPictureInPicture) { _, active in
                    guard case let .player(controller) = sink else { return }
                    if active {
                        controller.stop()
                    } else {
                        register()
                        controller.startIfEligible(reduceMotion: reduceMotion)
                    }
                }
                .onDisappear {
                    if let source { sink?.unregister(source) }
                    source = nil
                }
        }

        private func register() {
            guard let sink, !isPictureInPicture else { return }
            let current = source ?? engine.makeHueFrameSource()
            source = current
            sink.register(current)
        }
    }
#endif
