//
//  LumeCloudPairingCodeText.swift
//  Lume
//

import SwiftUI

/// A pairing code: left to right with Western digits in every locale, read
/// digit by digit by VoiceOver.
struct LumeCloudPairingCodeText: View {
    let code: String
    let size: CGFloat
    let tracking: CGFloat

    var body: some View {
        Text(verbatim: code)
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(tracking)
            .selectablePairingCode()
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
    }
}

private extension View {
    @ViewBuilder
    func selectablePairingCode() -> some View {
        #if os(tvOS)
            self
        #else
            textSelection(.enabled)
        #endif
    }
}
