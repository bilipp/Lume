//
//  AetherEngineHueFrameSource.swift
//  Lume
//
//  Hue frames from AetherEngine. The native path goes through the same
//  `AVPlayerItemVideoOutput` tap KSAVPlayer uses; the software path, which
//  serves interlaced live channels, is read back from its sample-buffer
//  layer. Only an audio-only session reports itself unsupported.
//

#if os(tvOS)
    import LumeAetherBridge

    final class AetherEngineHueFrameSource: HueFrameSource {
        private weak var coordinator: AetherEngineCoordinator?
        private let itemTap = HuePlayerItemTap()

        init(coordinator: AetherEngineCoordinator) {
            self.coordinator = coordinator
        }

        func latestFrame() -> HueFrameSample {
            guard let session = coordinator?.session else {
                detach()
                return .noFrame
            }
            guard session.isSampleable else {
                detach()
                return .unavailable(.unsupportedEngine)
            }
            if let player = session.nativePlayer {
                return itemTap.latestFrame(of: player)
            }
            detach()
            if let frame = session.displayedSoftwareFrame() {
                return .frame(.pixelBuffer(frame))
            }
            return .noFrame
        }

        func detach() {
            itemTap.detach()
        }
    }
#endif
