//
//  TVLumeCloudQRCard.swift
//  Lume
//

#if os(tvOS)

    import SwiftUI

    extension QRCodeView {
        /// The Lume Cloud steps' QR at TV size, on a white card so it scans
        /// against the dark pane.
        func tvLumeCloudQRCard() -> some View {
            frame(width: 240, height: 240)
                .padding(16)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

#endif
