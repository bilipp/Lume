//
//  PictureInPictureGeometryTests.swift
//  LumeTests
//
//  macOS sample-buffer PiP (KSPlayer, LumeEngine) needs Lume to redo AVKit's
//  panel geometry: AVKit leaves the picture unscaled and offset by the player
//  window's letterbox. These pin the transform `MacPictureInPictureScaler`
//  computes, on layer trees shaped like the ones AVKit actually builds in the
//  panel — measured from a running app, including the two layouts that cropped
//  the picture before the math took the picture layer's own rect into account.
//

@testable import Lume
import QuartzCore
import Testing

@MainActor
struct PictureInPictureGeometryTests {
    /// AVKit's layout in the panel: a host view, the video container in it, and
    /// the picture as the container's only sublayer.
    private struct Tree {
        let host = CALayer()
        let container = CALayer()
        let picture = CALayer()

        init(host hostSize: CGSize, container containerFrame: CGRect, picture pictureFrame: CGRect) {
            host.bounds = CGRect(origin: .zero, size: hostSize)
            container.frame = containerFrame
            picture.frame = pictureFrame
            host.addSublayer(container)
            container.addSublayer(picture)
        }

        /// Apply the computed transform and report where the picture lands.
        func landedPicture() throws -> CGRect {
            let transform = try #require(PictureInPictureGeometry.sublayerTransform(
                landing: picture.frame, inLayerAt: container.frame,
                anchorPoint: container.anchorPoint, ontoHostOf: host.bounds.size
            ))
            container.sublayerTransform = transform
            // From the picture's own space: a sublayer transform only acts on
            // sublayers, so this is the path that goes through it.
            return host.convert(picture.bounds, from: picture)
        }
    }

    private func expectClose(_ rect: CGRect, _ expected: CGRect) {
        #expect(abs(rect.minX - expected.minX) < 0.01)
        #expect(abs(rect.minY - expected.minY) < 0.01)
        #expect(abs(rect.width - expected.width) < 0.01)
        #expect(abs(rect.height - expected.height) < 0.01)
    }

    @Test func `picture already matching its host needs no transform`() throws {
        // Player window 16:10 with a letterboxed 16:9 video: AVKit's container
        // matches the host, but it pushes the picture up by the 50 pt bar.
        let tree = Tree(
            host: CGSize(width: 1600, height: 900),
            container: CGRect(x: 0, y: 0, width: 1600, height: 900),
            picture: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )
        tree.container.sublayerTransform = CATransform3DMakeTranslation(0, 50, 0)
        try expectClose(tree.landedPicture(), tree.host.bounds)
        #expect(CATransform3DIsIdentity(tree.container.sublayerTransform))
    }

    @Test func `picture larger than a resized host is scaled down onto it`() throws {
        // Player window resized to 900x1000 after the panel was built: the host
        // follows the new video rect, the container stays at the old one.
        let tree = Tree(
            host: CGSize(width: 900, height: 508),
            container: CGRect(x: 0, y: 0, width: 1600, height: 900),
            picture: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )
        try expectClose(tree.landedPicture(), tree.host.bounds)
    }

    @Test func `container sized to the whole letterboxed source still lands the picture`() throws {
        // The layout that defeated a container-to-host mapping: AVKit had grown
        // the container to the player window's size, bars included, while the
        // picture stayed at the video's rect.
        let tree = Tree(
            host: CGSize(width: 900, height: 508),
            container: CGRect(x: 0, y: 0, width: 900, height: 1000),
            picture: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )
        try expectClose(tree.landedPicture(), tree.host.bounds)
    }

    @Test func `offsets of the container and of the picture are both undone`() throws {
        let tree = Tree(
            host: CGSize(width: 567, height: 319),
            container: CGRect(x: 30, y: -40, width: 1000, height: 700),
            picture: CGRect(x: 12, y: 80, width: 960, height: 540)
        )
        try expectClose(tree.landedPicture(), tree.host.bounds)
    }

    @Test func `empty sizes produce no transform`() {
        #expect(PictureInPictureGeometry.sublayerTransform(
            landing: .zero, inLayerAt: CGRect(x: 0, y: 0, width: 10, height: 10),
            anchorPoint: CGPoint(x: 0.5, y: 0.5), ontoHostOf: CGSize(width: 10, height: 10)
        ) == nil)
        #expect(PictureInPictureGeometry.sublayerTransform(
            landing: CGRect(x: 0, y: 0, width: 10, height: 10), inLayerAt: .zero,
            anchorPoint: .zero, ontoHostOf: .zero
        ) == nil)
        #expect(PictureInPictureGeometry.scale(from: .zero, to: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func `panel scale fits the video view to the panel and is identity once it fits`() throws {
        let scale = try #require(PictureInPictureGeometry.scale(
            from: CGSize(width: 1600, height: 900), to: CGSize(width: 567, height: 319)
        ))
        #expect(abs(scale.m11 - 567.0 / 1600) < 0.0001)
        #expect(abs(scale.m22 - 319.0 / 900) < 0.0001)

        let fitted = try #require(PictureInPictureGeometry.scale(
            from: CGSize(width: 567, height: 319), to: CGSize(width: 567, height: 319)
        ))
        #expect(PictureInPictureGeometry.isApproximatelyEqual(fitted, CATransform3DIdentity))
    }

    @Test func `approximate equality ignores sub-thousandth noise but not real change`() {
        let base = CATransform3DMakeScale(0.5, 0.5, 1)
        var noisy = base
        noisy.m41 = 0.0004
        var moved = base
        moved.m42 = 1
        #expect(PictureInPictureGeometry.isApproximatelyEqual(base, noisy))
        #expect(!PictureInPictureGeometry.isApproximatelyEqual(base, moved))
    }
}
