import Foundation

/// Level math for the macOS player's app-level volume. Kept free of any
/// platform gate so it stays unit-testable on the iOS simulator.
nonisolated enum PlayerVolumeMath {
    static let keyStep: Float = 0.1

    static func clamped(_ level: Float) -> Float {
        guard !level.isNaN else { return 1 }
        return min(max(level, 0), 1)
    }

    static func effective(level: Float, muted: Bool) -> Float {
        muted ? 0 : clamped(level)
    }

    /// VLC's 0...200 scale goes past unity gain; Lume caps it at 100.
    static func vlcLevel(_ level: Float) -> Int32 {
        Int32((clamped(level) * 100).rounded())
    }

    /// Snaps to whole percents so repeated key steps land exactly on 0 and 1
    /// instead of drifting by Float rounding error.
    static func step(_ level: Float, by delta: Float) -> Float {
        clamped(((clamped(level) + delta) * 100).rounded() / 100)
    }

    static func glyph(for effective: Float) -> String {
        if effective <= 0 { return "speaker.slash.fill" }
        if effective < 1.0 / 3 { return "speaker.wave.1.fill" }
        if effective < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
