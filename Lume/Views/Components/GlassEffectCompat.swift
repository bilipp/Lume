//
//  GlassEffectCompat.swift
//  Lume
//
//  Liquid Glass degrades gracefully below the OS versions that introduced
//  `glassEffect` (iOS 26 / tvOS 26 / macOS 26 / visionOS 26). Earlier systems
//  fall back to a system material in the same shape so player controls stay
//  legible on iOS 18 / tvOS 18 / macOS 15 / visionOS 2.
//

import SwiftUI

/// The glass treatment a control wants, expressed without referencing the
/// iOS 26-only `Glass` type so it can be used from code that deploys to iOS 18.
enum GlassEffectStyle {
    /// Non-interactive regular glass.
    case regular
    /// Regular glass that lenses and lifts under interaction.
    case regularInteractive
    /// Interactive glass tinted toward `color` (e.g. the tvOS focus state).
    case tintedInteractive(Color)
}

extension View {
    /// Applies a Liquid Glass effect on OS 26+, falling back to a system
    /// material on earlier systems. A tinted style falls back to a solid fill
    /// of the tint colour so focus/emphasis stays readable.
    @ViewBuilder
    func glassEffectCompat(_ style: GlassEffectStyle = .regular, in shape: some Shape) -> some View {
        if #available(iOS 26, tvOS 26, macOS 26, visionOS 26, *) {
            glassEffect(style.resolvedGlass, in: shape)
        } else {
            switch style {
            case let .tintedInteractive(color):
                background(color, in: shape)
            case .regular, .regularInteractive:
                background(.regularMaterial, in: shape)
            }
        }
    }
}

@available(iOS 26, tvOS 26, macOS 26, visionOS 26, *)
private extension GlassEffectStyle {
    var resolvedGlass: Glass {
        switch self {
        case .regular: .regular
        case .regularInteractive: .regular.interactive()
        case let .tintedInteractive(color): .regular.tint(color).interactive()
        }
    }
}
