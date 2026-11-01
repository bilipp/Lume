//
//  AetherEngineEngineView+VideoSurface.swift
//  Lume
//
//  Hosts AetherEngine's player view. The bridge keeps AetherEngine out of
//  Lume's compile, so `AetherPlayerSurface` is out of reach; the session binds
//  its own `AetherPlayerView` (what the surface does) and this mounts it.
//

#if !os(visionOS)

    import LumeAetherBridge
    import SwiftUI

    #if canImport(UIKit)
        import UIKit

        struct AetherEngineVideoSurface: UIViewRepresentable {
            let videoView: LumeAetherPlatformView?

            func makeUIView(context _: Context) -> AetherEngineHostView {
                let view = AetherEngineHostView()
                view.backgroundColor = .black
                return view
            }

            func updateUIView(_ view: AetherEngineHostView, context _: Context) {
                view.install(videoView)
            }
        }

    #elseif canImport(AppKit)
        import AppKit

        struct AetherEngineVideoSurface: NSViewRepresentable {
            let videoView: LumeAetherPlatformView?

            func makeNSView(context _: Context) -> AetherEngineHostView {
                let view = AetherEngineHostView()
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.black.cgColor
                return view
            }

            func updateNSView(_ view: AetherEngineHostView, context _: Context) {
                view.install(videoView)
            }
        }
    #endif

    final class AetherEngineHostView: LumeAetherPlatformView {
        private weak var hosted: LumeAetherPlatformView?

        func install(_ videoView: LumeAetherPlatformView?) {
            guard hosted !== videoView else { return }
            hosted?.removeFromSuperview()
            hosted = nil
            guard let videoView else { return }
            videoView.frame = bounds
            #if canImport(UIKit)
                videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            #else
                videoView.autoresizingMask = [.width, .height]
            #endif
            addSubview(videoView)
            hosted = videoView
        }
    }

#endif
