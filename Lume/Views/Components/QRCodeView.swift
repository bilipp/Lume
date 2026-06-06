//
//  QRCodeView.swift
//  Lume
//
//  Renders a string as a QR code. Used by the Trakt device-flow UI so a viewer
//  on Apple TV can scan the activation URL with their phone instead of typing
//  it. CoreImage's generator is available on every Apple platform.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let string: String

    private static let context = CIContext()

    var body: some View {
        if let image = Self.makeImage(from: string) {
            image
                .resizable()
                .interpolation(.none) // keep the modules crisp when scaled up
                .scaledToFit()
                .accessibilityLabel("QR code")
        } else {
            Color.clear
        }
    }

    /// Generates a crisp QR `Image` for `string`, or nil if generation fails.
    private static func makeImage(from string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // Scale up from the 1-module-per-pixel native output so the rendered
        // CGImage is sharp rather than blurry.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
