//
//  HueFrameDownscaler.swift
//  Lume
//
//  Scales a decoded frame down to a `HueFrameGrid` with one
//  VTPixelTransferSession pass: any decoder format (BGRA, 8- and 10-bit
//  biplanar 4:2:0) goes in, Rec. 709 BGRA comes out. The session converts
//  from the colour tags on the source buffer, so a PQ or HLG frame arrives
//  mapped into SDR; an untagged one is taken as is.
//

import CoreVideo
import Foundation
import VideoToolbox

/// Not thread-safe: one owner calls it from one queue at a time.
final nonisolated class HueFrameDownscaler {
    let width: Int
    let height: Int

    private var session: VTPixelTransferSession?
    private var destination: CVPixelBuffer?

    init(width: Int = HueFrameGrid.standardWidth, height: Int = HueFrameGrid.standardHeight) {
        self.width = width
        self.height = height
    }

    deinit {
        if let session {
            VTPixelTransferSessionInvalidate(session)
        }
    }

    /// Nil when the transfer fails; the caller keeps the colours it had.
    func grid(from source: CVPixelBuffer) -> HueFrameGrid? {
        guard let session = session ?? makeSession(), let destination = destination ?? makeDestination() else {
            return nil
        }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else {
            return nil
        }
        return Self.readBGRA(destination, width: width, height: height)
    }

    private func makeSession() -> VTPixelTransferSession? {
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
              let created
        else { return nil }
        let properties: [CFString: CFTypeRef] = [
            kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_Normal,
            kVTPixelTransferPropertyKey_DownsamplingMode: kVTDownsamplingMode_Average,
            kVTPixelTransferPropertyKey_RealTime: kCFBooleanTrue,
            kVTPixelTransferPropertyKey_DestinationColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTPixelTransferPropertyKey_DestinationTransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTPixelTransferPropertyKey_DestinationYCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        for (key, value) in properties {
            VTSessionSetProperty(created, key: key, value: value)
        }
        session = created
        return created
    }

    private func makeDestination() -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created
        ) == kCVReturnSuccess else { return nil }
        destination = created
        return created
    }

    private static func readBGRA(_ buffer: CVPixelBuffer, width: Int, height: Int) -> HueFrameGrid? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for row in 0 ..< height {
            let line = bytes + row * bytesPerRow
            for column in 0 ..< width {
                let pixel = line + column * 4
                let offset = (row * width + column) * 3
                rgb[offset] = pixel[2]
                rgb[offset + 1] = pixel[1]
                rgb[offset + 2] = pixel[0]
            }
        }
        return HueFrameGrid(width: width, height: height, rgb: rgb)
    }
}
