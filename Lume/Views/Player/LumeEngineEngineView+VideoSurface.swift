import LumeEngine
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - Video surface

// Hosts the engine's `AVSampleBufferDisplayLayer` in the view hierarchy, kept in
// a companion file so `LumeEngineEngineView` stays under the file-length limit.
#if canImport(UIKit)
    struct LumeEngineVideoSurface: UIViewRepresentable {
        @ObservedObject var coordinator: LumeEngineCoordinator

        func makeUIView(context _: Context) -> LumeEngineHostView {
            LumeEngineHostView()
        }

        func updateUIView(_ view: LumeEngineHostView, context _: Context) {
            view.install(layer: coordinator.displayLayer)
        }
    }

    final class LumeEngineHostView: UIView {
        private weak var hosted: LumeDisplayLayer?

        func install(layer: LumeDisplayLayer?) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
            hosted = nil
            if let layer {
                layer.frame = bounds
                self.layer.addSublayer(layer)
                hosted = layer
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

#elseif canImport(AppKit)
    struct LumeEngineVideoSurface: NSViewRepresentable {
        @ObservedObject var coordinator: LumeEngineCoordinator

        func makeNSView(context _: Context) -> LumeEngineHostView {
            let view = LumeEngineHostView()
            view.wantsLayer = true
            return view
        }

        func updateNSView(_ view: LumeEngineHostView, context _: Context) {
            view.install(layer: coordinator.displayLayer)
        }
    }

    final class LumeEngineHostView: NSView {
        private weak var hosted: LumeDisplayLayer?

        func install(layer: LumeDisplayLayer?) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
            hosted = nil
            if let layer {
                layer.frame = bounds
                self.layer?.addSublayer(layer)
                hosted = layer
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
#endif
