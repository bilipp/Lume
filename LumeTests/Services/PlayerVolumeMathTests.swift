import Foundation
@testable import Lume
import Testing

struct PlayerVolumeMathTests {
    @Test func `clamp keeps in-range levels`() {
        #expect(PlayerVolumeMath.clamped(0) == 0)
        #expect(PlayerVolumeMath.clamped(0.5) == 0.5)
        #expect(PlayerVolumeMath.clamped(1) == 1)
    }

    @Test func `clamp bounds out-of-range levels`() {
        #expect(PlayerVolumeMath.clamped(-0.1) == 0)
        #expect(PlayerVolumeMath.clamped(-.infinity) == 0)
        #expect(PlayerVolumeMath.clamped(1.5) == 1)
        #expect(PlayerVolumeMath.clamped(.infinity) == 1)
        #expect(PlayerVolumeMath.clamped(.nan) == 1)
    }

    @Test func `effective level is zero when muted`() {
        #expect(PlayerVolumeMath.effective(level: 0.7, muted: true) == 0)
        #expect(PlayerVolumeMath.effective(level: 0.7, muted: false) == 0.7)
        #expect(PlayerVolumeMath.effective(level: 2, muted: false) == 1)
    }

    @Test func `vlc level maps to 0 through 100`() {
        #expect(PlayerVolumeMath.vlcLevel(0) == 0)
        #expect(PlayerVolumeMath.vlcLevel(0.5) == 50)
        #expect(PlayerVolumeMath.vlcLevel(1) == 100)
        #expect(PlayerVolumeMath.vlcLevel(0.326) == 33)
        #expect(PlayerVolumeMath.vlcLevel(0.335) == 34)
    }

    @Test func `vlc level never boosts past 100`() {
        #expect(PlayerVolumeMath.vlcLevel(2) == 100)
        #expect(PlayerVolumeMath.vlcLevel(-1) == 0)
        #expect(PlayerVolumeMath.vlcLevel(.nan) == 100)
    }

    @Test func `step stays within bounds`() {
        #expect(PlayerVolumeMath.step(1, by: PlayerVolumeMath.keyStep) == 1)
        #expect(PlayerVolumeMath.step(0, by: -PlayerVolumeMath.keyStep) == 0)
        #expect(PlayerVolumeMath.step(0.95, by: PlayerVolumeMath.keyStep) == 1)
        #expect(PlayerVolumeMath.step(0.05, by: -PlayerVolumeMath.keyStep) == 0)
        #expect(PlayerVolumeMath.step(0.5, by: PlayerVolumeMath.keyStep) == 0.6)
        #expect(PlayerVolumeMath.step(0.5, by: -PlayerVolumeMath.keyStep) == 0.4)
    }

    @Test func `repeated steps land exactly on the ends`() {
        var level: Float = 1
        for _ in 0 ..< 10 {
            level = PlayerVolumeMath.step(level, by: -PlayerVolumeMath.keyStep)
        }
        #expect(level == 0)
        for _ in 0 ..< 10 {
            level = PlayerVolumeMath.step(level, by: PlayerVolumeMath.keyStep)
        }
        #expect(level == 1)
    }

    @Test func `glyph buckets by level and mute`() {
        #expect(PlayerVolumeMath.glyph(for: PlayerVolumeMath.effective(level: 0.8, muted: true)) == "speaker.slash.fill")
        #expect(PlayerVolumeMath.glyph(for: 0) == "speaker.slash.fill")
        #expect(PlayerVolumeMath.glyph(for: 0.1) == "speaker.wave.1.fill")
        #expect(PlayerVolumeMath.glyph(for: 0.5) == "speaker.wave.2.fill")
        #expect(PlayerVolumeMath.glyph(for: 0.9) == "speaker.wave.3.fill")
        #expect(PlayerVolumeMath.glyph(for: 1) == "speaker.wave.3.fill")
    }
}
