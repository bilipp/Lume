//
//  TVLiveTVBackground.swift
//  Lume
//
//  The tvOS Live TV backdrop: a near-black fill lit from the top right by a
//  soft glow in the settled channel's logo colour, darkened towards the
//  bottom so the guide stays legible. Drawn with gradients rather than a
//  runtime blur, so it costs nothing per frame.
//

#if os(tvOS)
    import SwiftUI

    struct TVLiveTVBackground: View {
        /// `nil` paints the Live TV accent; only this view reads its glow.
        let hero: GuideHeroModel?

        /// `#090B10`.
        static let base = Color(.sRGB, red: 9 / 255, green: 11 / 255, blue: 16 / 255, opacity: 1)

        /// Laid out on the 1920 × 1080 design canvas and scaled to the screen.
        private static let canvasWidth: CGFloat = 1920
        private static let glowCenter = CGPoint(x: 1470, y: 230)
        /// The design's 1300 × 980 ellipse blurred by 170 pt: the gradient runs
        /// out roughly two blur radii beyond the ellipse's edge.
        private static let glowSize = CGSize(width: 1980, height: 1660)
        private static let glowOpacity = 0.5

        private var tint: Color {
            hero?.glowTint ?? LiveTVPalette.accent
        }

        var body: some View {
            let tint = tint
            GeometryReader { proxy in
                let scale = proxy.size.width / Self.canvasWidth
                let size = CGSize(width: Self.glowSize.width * scale, height: Self.glowSize.height * scale)
                Self.base
                    .overlay(alignment: .topLeading) {
                        Rectangle()
                            .fill(Self.glow(tint))
                            // The crossfade lives here, keyed on the colour,
                            // rather than in the model's write.
                            .animation(.easeInOut(duration: 0.6), value: tint)
                            .frame(width: size.width, height: size.height)
                            .offset(
                                x: Self.glowCenter.x * scale - size.width / 2,
                                y: Self.glowCenter.y * scale - size.height / 2
                            )
                    }
                    .overlay(Self.darkening)
                    .clipped()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        /// Approximates a blurred solid ellipse: a flat core, half strength at
        /// the original edge, nothing at the frame's edge.
        private static let glowFalloff: [(strength: Double, location: CGFloat)] = [
            (1, 0), (0.97, 0.25), (0.8, 0.45), (0.5, 0.62), (0.2, 0.8), (0.05, 0.92), (0, 1)
        ]

        private static func glow(_ tint: Color) -> EllipticalGradient {
            EllipticalGradient(
                stops: glowFalloff.map {
                    .init(color: tint.opacity(glowOpacity * $0.strength), location: $0.location)
                },
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
        }

        private static let darkening = LinearGradient(
            stops: [
                .init(color: base.opacity(0.15), location: 0),
                .init(color: base.opacity(0.7), location: 0.52),
                .init(color: base, location: 0.78),
                .init(color: base, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
#endif
