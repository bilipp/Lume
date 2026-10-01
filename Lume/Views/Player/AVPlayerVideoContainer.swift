//
//  AVPlayerVideoContainer.swift
//  Lume
//
//  Split out of `AVPlayerEngineView` to keep that file inside the 600-line cap.
//

import AVFoundation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// Hosts a view whose backing layer is an `AVPlayerLayer`. The coordinator owns
// the `AVPlayer` and is handed the layer once it mounts so it can drive content
// gravity and Picture in Picture.
#if os(macOS)
    struct AVPlayerVideoContainer: NSViewRepresentable {
        let coordinator: AVPlayerCoordinator

        func makeNSView(context _: Context) -> AVPlayerHostNSView {
            let view = AVPlayerHostNSView()
            coordinator.attach(layer: view.playerLayer)
            return view
        }

        func updateNSView(_: AVPlayerHostNSView, context _: Context) {}
    }

    /// AppKit has no `layerClass` hook, so the `AVPlayerLayer` is created and
    /// kept in sync with the view's bounds manually.
    final class AVPlayerHostNSView: NSView {
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
    struct AVPlayerVideoContainer: UIViewRepresentable {
        let coordinator: AVPlayerCoordinator

        func makeUIView(context _: Context) -> AVPlayerHostUIView {
            let view = AVPlayerHostUIView()
            view.backgroundColor = .black
            coordinator.attach(layer: view.playerLayer)
            return view
        }

        func updateUIView(_: AVPlayerHostUIView, context _: Context) {}
    }

    /// `layerClass` makes the view's backing layer an `AVPlayerLayer`, so it
    /// resizes with the view automatically.
    final class AVPlayerHostUIView: UIView {
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
