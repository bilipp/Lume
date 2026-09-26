//
//  MacPictureInPictureScaler.swift
//  Lume
//
//  Works around AVKit's broken sample-buffer Picture in Picture on macOS.
//
//  With an `AVSampleBufferDisplayLayer` content source — what KSPlayer and
//  LumeEngine both use — AVKit gets the PiP panel's geometry wrong three ways:
//
//  - It sizes its video view to the video's rect in the *player window* and
//    never scales it down to the panel, so the panel shows only the view's
//    bottom-left corner.
//  - It maps the video layer into that view with a sublayer transform that
//    folds in the player window's letterbox, and the layer clips to its
//    bounds — so a bar's worth of the picture is cut off along one edge, and
//    once the player window has been resized, most of the picture misses.
//  - An empty, opaque overlay sits in the same unscaled space and blacks out
//    the top of the picture once it does fit.
//
//  AVPlayerLayer PiP is unaffected. Filed with Apple as FB22411168; see
//  developer.apple.com/forums/thread/821582.
//
//  The panel lives in Lume's own process, so this scales the panel content to
//  the panel, maps the video layer exactly onto its host, and hides the
//  overlay. Each fix is computed from the geometry actually there, not assumed:
//  once AVKit gets it right, each comes out as a no-op.
//

import QuartzCore

/// The geometry behind `MacPictureInPictureScaler`, kept free of AppKit so the
/// tests — which run on iOS — can pin it.
nonisolated enum PictureInPictureGeometry {
    /// The scale that takes content of `size` to `target`, or nil for an empty
    /// size. Identity once the two already match.
    static func scale(from size: CGSize, to target: CGSize) -> CATransform3D? {
        guard size.width > 0, size.height > 0, target.width > 0, target.height > 0 else { return nil }
        return CATransform3DMakeScale(target.width / size.width, target.height / size.height, 1)
    }

    /// The sublayer transform for a layer at `layerFrame` in its host that lands
    /// `picture` — a rect in the layer's own coordinates — exactly on the host's
    /// bounds. Nil for an empty picture or host.
    ///
    /// A sublayer transform applies about the layer's anchor point, so with scale
    /// `s`, content point `p` must land on `(p - picture.origin) * s` in the host:
    /// the translation undoes the pivot, the layer's own offset in its host, and
    /// the picture's offset in the layer.
    static func sublayerTransform(
        landing picture: CGRect, inLayerAt layerFrame: CGRect, anchorPoint: CGPoint, ontoHostOf host: CGSize
    ) -> CATransform3D? {
        guard picture.width > 0, picture.height > 0, host.width > 0, host.height > 0 else { return nil }
        let scaleX = host.width / picture.width
        let scaleY = host.height / picture.height
        let pivotX = anchorPoint.x * layerFrame.width
        let pivotY = anchorPoint.y * layerFrame.height
        var transform = CATransform3DMakeScale(scaleX, scaleY, 1)
        transform.m41 = pivotX * (scaleX - 1) - layerFrame.minX - picture.minX * scaleX
        transform.m42 = pivotY * (scaleY - 1) - layerFrame.minY - picture.minY * scaleY
        return transform
    }

    /// Equal to within a thousandth of a point or scale step, and both affine.
    static func isApproximatelyEqual(_ lhs: CATransform3D, _ rhs: CATransform3D) -> Bool {
        let tolerance = 0.001
        return CATransform3DIsAffine(lhs) && CATransform3DIsAffine(rhs)
            && abs(lhs.m11 - rhs.m11) < tolerance && abs(lhs.m22 - rhs.m22) < tolerance
            && abs(lhs.m41 - rhs.m41) < tolerance && abs(lhs.m42 - rhs.m42) < tolerance
    }
}

#if os(macOS)
    import AppKit

    final class MacPictureInPictureScaler {
        static let shared = MacPictureInPictureScaler()

        private var observers: [NSObjectProtocol] = []
        private var offsetObservation: NSKeyValueObservation?
        private var attachTask: Task<Void, Never>?
        private var refitTask: Task<Void, Never>?

        private init() {}

        /// Call once PiP has started. The panel can appear a beat after the
        /// start callback, so this looks for it for a short while.
        func pictureInPictureDidStart() {
            attachTask?.cancel()
            attachTask = Task { @MainActor [weak self] in
                for _ in 0 ..< 40 {
                    if let content = Self.panelContentView() {
                        self?.attach(to: content)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }

        func pictureInPictureDidStop() {
            attachTask?.cancel()
            attachTask = nil
            detach()
        }

        private func attach(to content: NSView) {
            detach()
            // The viewer resizes the PiP window, and AVKit re-lays out its view
            // when the player window changes size: re-fit on either.
            for view in [content, Self.videoView(in: content)].compactMap(\.self) {
                view.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self, weak content] _ in
                    MainActor.assumeIsolated {
                        guard let content else { return }
                        self?.fit(content)
                    }
                })
            }
            // AVKit rewrites the video layer's transform whenever the player
            // window's geometry changes, which need not move any view.
            if let video = Self.videoView(in: content), let layer = Self.videoLayer(in: video) {
                offsetObservation = layer.observe(\.sublayerTransform) { layer, _ in
                    MainActor.assumeIsolated { Self.mapOntoHost(layer) }
                }
            }
            fit(content)
            // Not every AVKit geometry change is observable (the host layer's
            // bounds, for one), and a missed one leaves the picture cropped for
            // the rest of the session. `fit` is idempotent and cheap, so it also
            // re-runs on a slow beat for as long as the panel is up.
            refitTask = Task { @MainActor [weak self, weak content] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let content, content.window != nil else { return }
                    self?.fit(content)
                }
            }
        }

        private func detach() {
            refitTask?.cancel()
            refitTask = nil
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            offsetObservation = nil
        }

        private func fit(_ content: NSView) {
            guard let video = Self.videoView(in: content) else { return }
            Self.hideOverlays(in: video)
            if let layer = Self.videoLayer(in: video) { Self.mapOntoHost(layer) }

            // The panel's backing layer is anchored at its origin, which is also
            // where AVKit pins the video view, so a plain scale fits it.
            guard let layer = content.layer,
                  let transform = PictureInPictureGeometry.scale(from: video.frame.size, to: content.bounds.size),
                  !PictureInPictureGeometry.isApproximatelyEqual(layer.sublayerTransform, transform)
            else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = transform
            CATransaction.commit()
        }

        /// Give the video layer the sublayer transform that lands the picture
        /// exactly on its host's bounds — what AVKit's own transform should do.
        /// The picture is the layer's sublayer, and not necessarily the layer's
        /// size: AVKit can leave it at the video's rect while resizing the layer
        /// to the player window's, bars included.
        private static func mapOntoHost(_ layer: CALayer) {
            guard let host = layer.superlayer?.bounds.size,
                  let transform = PictureInPictureGeometry.sublayerTransform(
                      landing: layer.sublayers?.first?.frame ?? layer.bounds,
                      inLayerAt: layer.frame, anchorPoint: layer.anchorPoint, ontoHostOf: host
                  ),
                  // Setting it re-enters through the observation; stop once it holds.
                  !PictureInPictureGeometry.isApproximatelyEqual(layer.sublayerTransform, transform)
            else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = transform
            CATransaction.commit()
        }

        // MARK: - Finding AVKit's views

        /// Matched by class name: AVKit's panel and views are private. A miss
        /// just leaves PiP as AVKit drew it.
        private static func panelContentView() -> NSView? {
            NSApp.windows.first { className(of: $0).contains("PIPPanel") }?.contentView
        }

        private static func videoView(in content: NSView) -> NSView? {
            content.subviews.first { className(of: $0).contains("SampleBufferDisplayLayerView") }
        }

        /// The layer that draws the picture and carries the letterbox offset.
        private static func videoLayer(in view: NSView) -> CALayer? {
            func search(_ layer: CALayer) -> CALayer? {
                if className(of: layer).contains("VideoContainerLayer") { return layer }
                for sublayer in layer.sublayers ?? [] {
                    if let found = search(sublayer) { return found }
                }
                return nil
            }
            return view.layer.flatMap(search)
        }

        /// The overlay carries no picture, only an opaque black backing.
        private static func hideOverlays(in view: NSView) {
            for subview in view.subviews {
                if className(of: subview) == "AVPictureInPictureCALayerHostView" {
                    subview.isHidden = true
                } else {
                    hideOverlays(in: subview)
                }
            }
        }

        private static func className(of object: AnyObject) -> String {
            String(describing: type(of: object))
        }
    }
#endif
