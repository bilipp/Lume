//
//  BackgroundExtensionCompat.swift
//  Lume
//
//  `backgroundExtensionEffect()` (OS 26) mirrors and blurs a view into the
//  safe area around it, so hero artwork runs under side bars and a trailing
//  status column without moving the content laid out over it. Earlier systems
//  keep the artwork inside the safe area, as before.
//

import SwiftUI

extension View {
    /// Extends this background view into the surrounding safe area on OS 26+;
    /// no-op on earlier systems. Apply it to artwork only — text and controls
    /// would be mirrored too.
    @ViewBuilder
    func backgroundExtensionEffectIfAvailable() -> some View {
        if #available(iOS 26, tvOS 26, macOS 26, visionOS 26, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }
}
