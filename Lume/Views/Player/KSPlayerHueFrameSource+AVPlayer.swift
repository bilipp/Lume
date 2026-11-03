//
//  KSPlayerHueFrameSource+AVPlayer.swift
//  Lume
//
//  KSAVPlayer draws through AVPlayerLayer and keeps no frame of its own, so
//  Hue adds an `AVPlayerItemVideoOutput` to its current item. The output
//  exists only while sync asks for frames, follows the player onto each new
//  item, and comes off again on `detach()`.
//

#if os(tvOS)
    import AVFoundation
    import QuartzCore

    final class HuePlayerItemTap {
        private static let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // Scaled by AVFoundation before the copy, so a 4K frame is never
            // converted to BGRA at full size only to become a 32x18 grid.
            kCVPixelBufferWidthKey as String: HueFrameGrid.standardWidth * 2,
            kCVPixelBufferHeightKey as String: HueFrameGrid.standardHeight * 2,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]

        private weak var item: AVPlayerItem?
        private var output: AVPlayerItemVideoOutput?
        private var lastFrame: CVPixelBuffer?

        /// Repeats the last frame while the output has nothing newer, so a
        /// paused or buffering picture keeps its colours.
        func latestFrame(of player: AVPlayer) -> HueFrameSample {
            guard let current = player.currentItem else {
                detach()
                return .noFrame
            }
            if current !== item {
                attach(to: current)
            }
            if let output {
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
                {
                    lastFrame = buffer
                }
            }
            guard let lastFrame else { return .noFrame }
            return .frame(.pixelBuffer(lastFrame))
        }

        func detach() {
            if let output {
                item?.remove(output)
            }
            output = nil
            item = nil
            lastFrame = nil
        }

        private func attach(to newItem: AVPlayerItem) {
            detach()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.pixelBufferAttributes)
            newItem.add(output)
            self.output = output
            item = newItem
        }
    }
#endif
