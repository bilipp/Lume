//
//  AppearanceSettings.swift
//  Lume
//
//  The user's app-wide appearance override (System / Dark / Light). Persisted
//  as a plain string and applied at the scene root, so a device in Light Mode
//  can still run Lume permanently dark (and vice versa). `system` keeps the
//  previous follow-the-device behaviour. Not offered on tvOS — the TV UI is
//  designed dark and the whole app is pinned dark via the Info.plist
//  `UIUserInterfaceStyle` key (`INFOPLIST_KEY_UIUserInterfaceStyle
//  [sdk=appletv*]` in the target build settings), so the applier is a no-op.
//  A runtime window override is not enough on tvOS: the system draws the
//  scene backdrop behind the (transparent) window from the *device*
//  appearance, so content pinned dark still sat on a light backdrop (#140).
//
//  Applied as a *window-level* style override (`overrideUserInterfaceStyle` /
//  `NSApp.appearance`) rather than `.preferredColorScheme`: once that modifier
//  has set a non-nil scheme, passing `nil` never returns the presentation to
//  following the device, and a change doesn't reach an already-presented sheet
//  (the Settings sheet stayed in the old scheme). The window override resets
//  cleanly and restyles everything in the window immediately.
//

import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    static let storageKey = "app.appearance"
    static let defaultValue: AppAppearance = .system

    /// Resolves a persisted raw value, falling back to `system` for missing
    /// or unknown values.
    static func resolve(_ raw: String) -> AppAppearance {
        AppAppearance(rawValue: raw) ?? defaultValue
    }

    var id: String {
        rawValue
    }

    #if canImport(UIKit) && !os(tvOS)
        /// The window override style; `.unspecified` follows the device.
        var interfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: .unspecified
            case .dark: .dark
            case .light: .light
            }
        }

    #elseif canImport(AppKit)
        /// The app-wide appearance; `nil` follows the device.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .dark: NSAppearance(named: .darkAqua)
            case .light: NSAppearance(named: .aqua)
            }
        }
    #endif

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

extension View {
    /// Applies the user's appearance override to the hosting window (see the
    /// file header for why this is not `.preferredColorScheme`). Views that
    /// force their own scheme (the players' `.preferredColorScheme(.dark)`)
    /// still win for their presentation. No-op on tvOS, which has no
    /// Appearance setting — the TV UI is pinned dark by the Info.plist
    /// `UIUserInterfaceStyle` key (see the file header).
    func appAppearance(_ appearance: AppAppearance) -> some View {
        #if os(tvOS)
            return self
        #elseif canImport(UIKit)
            return background(
                AppearanceWindowApplier(style: appearance.interfaceStyle)
                    .allowsHitTesting(false)
            )
        #elseif canImport(AppKit)
            return onChange(of: appearance, initial: true) { _, newValue in
                NSApp.appearance = newValue.nsAppearance
            }
        #endif
    }
}

#if canImport(UIKit) && !os(tvOS)
    /// A zero-size probe that reaches its hosting `UIWindow` and sets
    /// `overrideUserInterfaceStyle` — restyling every presentation in the
    /// window (including open sheets) and cleanly reverting to the device
    /// appearance with `.unspecified`.
    private struct AppearanceWindowApplier: UIViewRepresentable {
        let style: UIUserInterfaceStyle

        func makeUIView(context _: Context) -> ProbeView {
            ProbeView()
        }

        func updateUIView(_ view: ProbeView, context _: Context) {
            view.style = style
        }

        final class ProbeView: UIView {
            var style: UIUserInterfaceStyle = .unspecified {
                didSet { window?.overrideUserInterfaceStyle = style }
            }

            /// The window is nil during makeUIView; re-apply once attached.
            override func didMoveToWindow() {
                super.didMoveToWindow()
                window?.overrideUserInterfaceStyle = style
            }
        }
    }
#endif
