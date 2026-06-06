//
//  TVDetailButtons.swift
//  Lume
//
//  Focus-aware button styles and button components for the tvOS movie and
//  series detail screens. Split out from TVDetailComponents to keep each file
//  focused: this file owns the interactive controls (primary / glass / card
//  styles and the Play and secondary action buttons), while TVDetailComponents
//  owns the static layout pieces.
//
//  Everything here is tuned for the focus engine: cards and buttons lift and
//  gain a shadow when focused, mirroring tvOS system controls.
//

#if os(tvOS)

    import SwiftUI

    /// A translucent pill for secondary hero actions (Favorite, Watched). Fills
    /// the available width so a row of these matches the Play button above, and
    /// tints solid white when focused.
    struct TVGlassButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let foreground: Color = isFocused ? .black : .white
                let background: AnyShapeStyle = isFocused
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(.regularMaterial)
                let shadowOpacity: Double = isFocused ? 0.4 : 0
                return configuration.label
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(background)
                    )
                    .scaleEffect(isFocused ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(shadowOpacity), radius: 18, y: 10)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
            }
        }
    }

    /// Generic card lift used by episode, poster and cast cards.
    struct TVCardButtonStyle: ButtonStyle {
        var focusScale: CGFloat = 1.08

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, focusScale: focusScale)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let focusScale: CGFloat
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let pressed = configuration.isPressed
                let scale: CGFloat = pressed ? focusScale * 0.97 : (isFocused ? focusScale : 1.0)
                let shadowOpacity: Double = isFocused ? 0.5 : 0
                return configuration.label
                    // The shadow is applied *before* the scale transform so it is
                    // rasterised once and then scaled as a bitmap, rather than the
                    // GPU re-blurring it on every frame of the focus animation
                    // (which happens when scaleEffect precedes shadow). A smaller
                    // radius further cuts the per-frame blur cost while still
                    // reading as a clear focus lift on the 10-foot UI.
                    .shadow(color: .black.opacity(shadowOpacity), radius: 12, y: 8)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
                    .animation(.easeOut(duration: 0.1), value: pressed)
            }
        }
    }

    // MARK: - Buttons

    struct TVPlayButton: View {
        let title: String
        var systemImage: String = "play.fill"
        var isEnabled: Bool = true
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(TVGlassButtonStyle())
            .disabled(!isEnabled)
        }
    }

    /// An icon-only secondary action (Favorite / Watched) shown below the Play
    /// button. The `title` is used as the accessibility label since no text is
    /// rendered.
    struct TVSecondaryActionButton: View {
        let title: String
        let systemImage: String
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(TVGlassButtonStyle())
            .accessibilityLabel(title)
        }
    }

#endif
