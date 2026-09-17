//
//  MultiViewTilePlayer+Engines.swift
//  Lume
//
//  One video-only surface per playback engine, for `MultiViewTilePlayer`. Each
//  reuses the engine's existing coordinator — so a tile inherits its startup
//  watchdog and reconnect behaviour — but marks itself embedded, which declines
//  Picture in Picture and (for AVPlayer) the AirPlay route: those belong to the
//  single full-screen stream, not to one of four tiles.
//

import AVFoundation
import KSPlayer
import OSLog
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - KSPlayer

struct MultiViewKSTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    /// Bounded backoff for a *mid-stream* drop. KSPlayer has no safe in-place
    /// re-prepare (see `KSPlayerEngineView+Playback`), so a reconnect here bumps
    /// the id below, which tears the layer down and builds a fresh one.
    @State private var reconnector = PlaybackRetryController()
    @State private var reloadToken = 0
    @State private var hasStarted = false
    @State private var startupWatchdog: Task<Void, Never>?

    var body: some View {
        KSVideoPlayer(
            coordinator: coordinator,
            url: media.url,
            options: KSPlayerOptionsFactory.make(for: media, allowsPictureInPicture: false)
        )
        .onStateChanged { _, state in
            // Deferred so the mutations below never land inside a SwiftUI view
            // update pass, exactly as the full-screen KSPlayer host does it.
            DispatchQueue.main.async { handle(state) }
        }
        .id(reloadToken)
        .onAppear {
            coordinator.isMuted = isMuted
            startWatchdog()
        }
        .onDisappear {
            startupWatchdog?.cancel()
            reconnector.cancel()
            coordinator.resetPlayer()
        }
        .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
    }

    private func handle(_ state: KSPlayerState) {
        // The layer is created during layout, so re-assert the mute as soon as
        // there is a player to apply it to.
        coordinator.isMuted = isMuted
        switch state {
        case .bufferFinished:
            reconnector.reset()
            guard !hasStarted else { return }
            hasStarted = true
            startupWatchdog?.cancel()
            onPlaybackStarted()
        case .error:
            startupWatchdog?.cancel()
            guard hasStarted else {
                onPlaybackFailed()
                return
            }
            // The stream had been playing and dropped — reconnect quietly rather
            // than replacing the tile with a failure badge.
            reconnector.scheduleRetry { reloadToken += 1 }
        default:
            break
        }
    }

    /// KSPlayer can hang in `.preparing`/`.buffering` indefinitely without ever
    /// emitting `.error`, which would leave the tile spinning forever.
    private func startWatchdog() {
        startupWatchdog?.cancel()
        let timeout = usesQuickStartupTimeout
            ? MultiViewTilePlayer.fallbackStartupTimeout
            : MultiViewTilePlayer.startupTimeout
        startupWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, !hasStarted else { return }
            onPlaybackFailed()
        }
    }
}

// MARK: - VLCKit

struct MultiViewVLCTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = VLCPlayerCoordinator(isEmbedded: true)

    var body: some View {
        MultiViewVLCSurface(coordinator: coordinator)
            .onAppear {
                coordinator.isMuted = isMuted
                coordinator.startupTimeout = usesQuickStartupTimeout
                    ? MultiViewTilePlayer.fallbackStartupTimeout
                    : MultiViewTilePlayer.startupTimeout
                coordinator.onPlaybackFailure = onPlaybackFailed
                coordinator.configure(media: media)
            }
            .onDisappear { coordinator.tearDown() }
            .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                // libVLC applies the mute to the audio output, which only exists
                // once the stream is open.
                coordinator.isMuted = isMuted
                if started {
                    onPlaybackStarted()
                }
            }
    }
}

// MARK: - AVPlayer

struct MultiViewAVTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = AVPlayerCoordinator(isEmbedded: true)

    var body: some View {
        MultiViewAVSurface(coordinator: coordinator)
            .onAppear {
                coordinator.isMuted = isMuted
                coordinator.startupTimeout = usesQuickStartupTimeout
                    ? MultiViewTilePlayer.fallbackStartupTimeout
                    : MultiViewTilePlayer.startupTimeout
                coordinator.onPlaybackFailure = onPlaybackFailed
                coordinator.configure(media: media)
            }
            .onDisappear { coordinator.tearDown() }
            .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                if started {
                    onPlaybackStarted()
                }
            }
    }
}

// MARK: - LumeEngine

struct MultiViewLumeTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = LumeEngineCoordinator()
    /// The engine never retries on its own schedule — reconnect policy is the
    /// app's job (see the engine's contract in CLAUDE.md).
    @State private var reconnector = PlaybackRetryController()

    var body: some View {
        LumeEngineVideoSurface(coordinator: coordinator)
            .onAppear {
                coordinator.isEmbedded = true
                coordinator.isMuted = isMuted
                coordinator.startupTimeout = usesQuickStartupTimeout
                    ? MultiViewTilePlayer.fallbackStartupTimeout
                    : MultiViewTilePlayer.startupTimeout
                coordinator.onPlaybackFailure = onPlaybackFailed
                coordinator.onStalled = { reconnector.scheduleRetry { coordinator.reload() } }
                coordinator.onRecovered = { reconnector.reset() }
                coordinator.configure(media: media)
            }
            .onDisappear {
                reconnector.cancel()
                coordinator.tearDown()
            }
            .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                if started {
                    onPlaybackStarted()
                }
            }
    }
}

// MARK: - Platform view bridges

// Hosts a view whose backing layer is an `AVPlayerLayer`, sized by the tile.
#if os(macOS)
    private struct MultiViewAVSurface: NSViewRepresentable {
        let coordinator: AVPlayerCoordinator

        func makeNSView(context _: Context) -> MultiViewAVHostView {
            let view = MultiViewAVHostView()
            coordinator.attach(layer: view.playerLayer)
            return view
        }

        func updateNSView(_: MultiViewAVHostView, context _: Context) {}
    }

    private final class MultiViewAVHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
            layer?.backgroundColor = NSColor.black.cgColor
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
#else
    private struct MultiViewAVSurface: UIViewRepresentable {
        let coordinator: AVPlayerCoordinator

        func makeUIView(context _: Context) -> MultiViewAVHostView {
            let view = MultiViewAVHostView()
            view.backgroundColor = .black
            coordinator.attach(layer: view.playerLayer)
            return view
        }

        func updateUIView(_: MultiViewAVHostView, context _: Context) {}
    }

    private final class MultiViewAVHostView: UIView {
        // swiftlint:disable:next static_over_final_class
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            // swiftlint:disable:next force_cast
            layer as! AVPlayerLayer
        }
    }
#endif

// Hosts the plain platform view VLC renders into.
#if os(macOS)
    private struct MultiViewVLCSurface: NSViewRepresentable {
        let coordinator: VLCPlayerCoordinator

        func makeNSView(context _: Context) -> NSView {
            // Deliberately not layer-backed, for the same reason as the
            // full-screen VLC host: VLCKit's macOS output inserts a legacy
            // `NSOpenGLView`, which aborts inside a layer-backed tree.
            let view = NSView()
            coordinator.attach(hostView: view)
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
#else
    private struct MultiViewVLCSurface: UIViewRepresentable {
        let coordinator: VLCPlayerCoordinator

        func makeUIView(context _: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .black
            coordinator.attach(hostView: view)
            return view
        }

        func updateUIView(_: UIView, context _: Context) {}
    }
#endif
