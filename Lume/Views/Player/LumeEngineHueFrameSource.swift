//
//  LumeEngineHueFrameSource.swift
//  Lume
//
//  Hue frames from LumeEngine's own colour sampler: the render pump reads a
//  grid from each frame it enqueues, and this reads the one on screen now.
//  Each session brings a fresh sampler, off until Hue turns it on.
//

#if os(tvOS)
    import LumeEngine

    final class LumeEngineHueFrameSource: HueFrameSource {
        private static let configuration = VideoSampleTap.Configuration(
            columns: HueFrameGrid.standardWidth,
            rows: HueFrameGrid.standardHeight,
            pointsPerCell: 2
        )

        private weak var coordinator: LumeEngineCoordinator?
        private weak var tap: VideoSampleTap?
        private var lastGrid: (pts: Int64, grid: HueFrameGrid)?

        init(coordinator: LumeEngineCoordinator) {
            self.coordinator = coordinator
        }

        func latestFrame() -> HueFrameSample {
            guard let session = coordinator?.session else {
                detach()
                return .noFrame
            }
            let samples = session.videoSamples
            if samples !== tap {
                detach()
                samples.configuration = Self.configuration
                samples.isEnabled = true
                tap = samples
            }
            guard let sample = samples.sample(atOrBefore: session.renderer.currentTime) else {
                return .noFrame
            }
            if let lastGrid, lastGrid.pts == sample.pts {
                return .frame(.grid(lastGrid.grid))
            }
            let colors = sample.colors.map {
                HueFrameGrid.LinearColor(red: $0.red, green: $0.green, blue: $0.blue)
            }
            guard let grid = HueFrameGrid(width: sample.columns, height: sample.rows, linear: colors) else {
                return .noFrame
            }
            lastGrid = (sample.pts, grid)
            return .frame(.grid(grid))
        }

        func detach() {
            tap?.isEnabled = false
            tap = nil
            lastGrid = nil
        }
    }
#endif
